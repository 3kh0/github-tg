require "sinatra"
require "json"
require "net/http"
require "uri"
require "time"
require "redis"
require "dotenv/load"
require_relative "notifications"

TELEGRAM_TOKEN          = ENV.fetch("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID        = ENV.fetch("TELEGRAM_CHAT_ID")
GITHUB_TOKEN            = ENV.fetch("GITHUB_TOKEN")
REDIS_URL               = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
TELEGRAM_WEBHOOK_URL    = ENV["TELEGRAM_WEBHOOK_URL"]    # e.g. https://gh-tg.example.com/telegram
TELEGRAM_WEBHOOK_SECRET = ENV["TELEGRAM_WEBHOOK_SECRET"] # random string, recommended

POLL_INTERVAL = 60
SEEN_LIMIT    = 1000

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567).to_i

REDIS              = Redis.new(url: REDIS_URL)
LAST_MODIFIED_KEY  = "last_modified"
SEEN_KEY           = "seen"
TG_OFFSET_KEY      = "telegram_offset"

def already_seen?(key)
  !REDIS.zscore(SEEN_KEY, key).nil?
end

def mark_seen!(key, score)
  REDIS.multi do |tx|
    tx.zadd(SEEN_KEY, score, key)
    tx.zremrangebyrank(SEEN_KEY, 0, -SEEN_LIMIT - 1)
  end
end

def telegram_api(method, params = {})
  uri = URI("https://api.telegram.org/bot#{TELEGRAM_TOKEN}/#{method}")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  req.body = JSON.generate(params)
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                        read_timeout: 60) { |h| h.request(req) }
  parsed = JSON.parse(res.body) rescue {}
  warn "telegram #{method} error: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  parsed
end

def send_notification(notification)
  text = Notifications.format(notification, token: GITHUB_TOKEN)
  telegram_api("sendMessage", {
    "chat_id"                  => TELEGRAM_CHAT_ID,
    "text"                     => text,
    "parse_mode"               => "HTML",
    "disable_web_page_preview" => true,
    "reply_markup"             => Notifications.keyboard_for(notification["id"])
  })
end

def fetch_notifications(last_modified)
  uri = URI("https://api.github.com/notifications")
  req = Net::HTTP::Get.new(uri)
  req["Authorization"]        = "Bearer #{GITHUB_TOKEN}"
  req["Accept"]               = "application/vnd.github+json"
  req["X-GitHub-Api-Version"] = "2022-11-28"
  req["User-Agent"]           = "github-tg"
  req["If-Modified-Since"]    = last_modified if last_modified

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  poll_interval = res["X-Poll-Interval"]&.to_i

  case res
  when Net::HTTPNotModified
    [[], last_modified, poll_interval]
  when Net::HTTPSuccess
    [JSON.parse(res.body), res["Last-Modified"] || last_modified, poll_interval]
  else
    warn "github api error: #{res.code} #{res.body}"
    [[], last_modified, poll_interval]
  end
end

def poll_github_once(first_run:)
  last_modified = REDIS.get(LAST_MODIFIED_KEY)
  notifications, new_last_modified, server_interval =
    fetch_notifications(last_modified)

  notifications.sort_by { |n| n["updated_at"].to_s }.each do |n|
    key = "#{n['id']}@#{n['updated_at']}"
    next if already_seen?(key)

    score = (Time.parse(n["updated_at"]).to_f rescue Time.now.to_f)
    send_notification(n) unless first_run
    mark_seen!(key, score)
  end

  REDIS.set(LAST_MODIFIED_KEY, new_last_modified) if new_last_modified
  server_interval
end

def handle_callback(query)
  data       = query["data"].to_s
  action, id = data.split(":", 2)
  msg        = query["message"] || {}
  chat_id    = msg.dig("chat", "id")
  message_id = msg["message_id"]

  endpoint, ok_msg = case action
                     when "done"
                       ["/notifications/threads/#{id}", "✅ Marked as done"]
                     when "unsub"
                       ["/notifications/threads/#{id}/subscription", "🔕 Unsubscribed"]
                     end

  unless endpoint
    telegram_api("answerCallbackQuery",
                 "callback_query_id" => query["id"],
                 "text"              => "Unknown action")
    return
  end

  res = Notifications.github_api(:delete, endpoint, token: GITHUB_TOKEN)
  if res.is_a?(Net::HTTPSuccess)
    telegram_api("answerCallbackQuery",
                 "callback_query_id" => query["id"],
                 "text"              => ok_msg)
    telegram_api("editMessageReplyMarkup",
                 "chat_id"      => chat_id,
                 "message_id"   => message_id,
                 "reply_markup" => { "inline_keyboard" => [] })
  else
    telegram_api("answerCallbackQuery",
                 "callback_query_id" => query["id"],
                 "text"              => "GitHub error #{res.code}",
                 "show_alert"        => true)
  end
end

def poll_telegram_once
  offset = REDIS.get(TG_OFFSET_KEY)&.to_i
  params = { "timeout" => 25, "allowed_updates" => ["callback_query"] }
  params["offset"] = offset if offset

  result = telegram_api("getUpdates", params)
  (result["result"] || []).each do |update|
    handle_callback(update["callback_query"]) if update["callback_query"]
    REDIS.set(TG_OFFSET_KEY, update["update_id"] + 1)
  end
end


USE_WEBHOOK = TELEGRAM_WEBHOOK_URL && !TELEGRAM_WEBHOOK_URL.empty?

if USE_WEBHOOK
  params = {
    "url"             => TELEGRAM_WEBHOOK_URL,
    "allowed_updates" => ["callback_query"]
  }
  params["secret_token"] = TELEGRAM_WEBHOOK_SECRET if TELEGRAM_WEBHOOK_SECRET
  telegram_api("setWebhook", params)
  warn "telegram: webhook registered at #{TELEGRAM_WEBHOOK_URL}"
else
  telegram_api("deleteWebhook", "drop_pending_updates" => false)
  warn "telegram: using getUpdates"
end


Thread.new do
  first_run = REDIS.get(LAST_MODIFIED_KEY).nil? && REDIS.zcard(SEEN_KEY).zero?
  loop do
    interval = POLL_INTERVAL
    begin
      server_interval = poll_github_once(first_run: first_run)
      first_run = false
      interval = [server_interval || POLL_INTERVAL, POLL_INTERVAL].max
    rescue StandardError => e
      warn "github poll error: #{e.class}: #{e.message}"
    end
    sleep interval
  end
end

unless USE_WEBHOOK
  Thread.new do
    loop do
      begin
        poll_telegram_once
      rescue StandardError => e
        warn "telegram poll error: #{e.class}: #{e.message}"
        sleep 5
      end
    end
  end
end


get "/" do
  "we up"
end

get "/health" do
  content_type :json
  JSON.generate(
    ok:            true,
    mode:          USE_WEBHOOK ? "webhook" : "polling",
    last_modified: REDIS.get(LAST_MODIFIED_KEY),
    seen_count:    REDIS.zcard(SEEN_KEY)
  )
end

post "/telegram" do
  if TELEGRAM_WEBHOOK_SECRET && !TELEGRAM_WEBHOOK_SECRET.empty?
    expected = TELEGRAM_WEBHOOK_SECRET
    actual   = request.env["HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN"]
    halt 401, "unauthorized" unless actual == expected
  end

  payload = JSON.parse(request.body.read) rescue {}
  handle_callback(payload["callback_query"]) if payload["callback_query"]
  status 200
end
