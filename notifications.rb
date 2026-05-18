require "json"
require "net/http"
require "uri"

module Notifications
  REASON = {
    "assign"           => "you were assigned",
    "author"           => "you authored",
    "comment"          => "new comment",
    "ci_activity"      => "CI activity",
    "invitation"       => "you were invited",
    "manual"           => "subscribed",
    "mention"          => "you were mentioned",
    "review_requested" => "review requested",
    "security_alert"   => "security alert",
    "state_change"     => "state changed",
    "subscribed"       => "watching",
    "team_mention"     => "team mentioned"
  }.freeze

  TYPE_EMOJI = {
    "PullRequest"                  => "🔀",
    "Issue"                        => "📝",
    "Commit"                       => "🔨",
    "Release"                      => "🚀",
    "Discussion"                   => "💬",
    "RepositoryVulnerabilityAlert" => "🚨",
    "CheckSuite"                   => "✅"
  }.freeze

  STATE_EMOJI = { "open" => "🟢", "closed" => "🔴", "merged" => "🟣", "draft" => "⚪️" }.freeze
  EXTRA_EMOJI = { "label" => "🏷", "review" => "👀", "comment" => "💬", "default" => "📣" }.freeze
  HTTP_VERB   = { get: Net::HTTP::Get, delete: Net::HTTP::Delete, patch: Net::HTTP::Patch, post: Net::HTTP::Post }.freeze

  MENTION_RE = /@([A-Za-z0-9][A-Za-z0-9-]{0,38})(\[bot\])?/

  module_function

  def type_icon(t)  = TYPE_EMOJI[t] || EXTRA_EMOJI["default"]
  def extra_icon(n) = EXTRA_EMOJI[n] || EXTRA_EMOJI["default"]
  def state_text(n) = "#{STATE_EMOJI[n]} #{n}"
  def escape_html(s) = s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

  def github_api(method, path_or_url, token:, body: nil)
    uri = URI(path_or_url.to_s.start_with?("http") ? path_or_url : "https://api.github.com#{path_or_url}")
    req = HTTP_VERB.fetch(method).new(uri)
    req["Authorization"]        = "Bearer #{token}"
    req["Accept"]               = "application/vnd.github+json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["User-Agent"]           = "github-tg"
    (req["Content-Type"] = "application/json"; req.body = JSON.generate(body)) if body
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  end

  def github_get(url, token:)
    res = github_api(:get, url, token: token)
    res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
  rescue StandardError => e
    warn "github_get error: #{e.class}: #{e.message}"
    nil
  end

  def suburl(url)
    url&.sub("https://api.github.com/repos/", "https://github.com/")
       &.sub("/pulls/", "/pull/")
       &.sub(%r{/commits/([0-9a-f]+)$}, '/commit/\1')
  end

  def user_url(login)
    login.to_s.end_with?("[bot]") ? "https://github.com/apps/#{login.sub(/\[bot\]$/, '')}" : "https://github.com/#{login}"
  end

  def user_link(login)
    return "" if login.nil? || login.empty?
    %(<a href="#{user_url(login)}">@#{escape_html(login)}</a>)
  end

  def linkm(escaped_text)
    escaped_text.gsub(/@([A-Za-z0-9][A-Za-z0-9-]{0,38})(\[bot\])?/) do
      n, s = ::Regexp.last_match(1), ::Regexp.last_match(2).to_s
      %(<a href="https://github.com/#{s.empty? ? '' : 'apps/'}#{n}">@#{n}#{s}</a>)
    end
  end

  def rich(text) = linkm(escape_html(text))

  def state(type, d)
    case type
    when "PullRequest"
      state_text(d["merged"] ? "merged" : d["state"] == "closed" ? "closed" : d["draft"] ? "draft" : "open")
    when "Issue"
      state_text(d["state"] == "open" ? "open" : "closed")
    end
  end

  def format(notification, token:)
    sub_url = notification.dig("subject", "url")
    lc_url  = notification.dig("subject", "latest_comment_url")
    d       = sub_url ? github_get(sub_url, token: token) : nil
    lc      = (lc_url && lc_url != sub_url) ? github_get(lc_url, token: token) : nil

    repo   = notification.dig("repository", "full_name") || "unknown"
    type   = notification.dig("subject", "type") || "Notification"
    title  = notification.dig("subject", "title") || ""
    reason = REASON[notification["reason"]] || notification["reason"].to_s
    url    = suburl(sub_url) || "https://github.com/#{repo}"
    num    = d && d["number"]

    latest_commit = nil
    if type == "PullRequest" && notification["reason"] == "review_requested" && d
      sha = d.dig("head", "sha")
      commit_data = sha ? github_get("https://api.github.com/repos/#{repo}/commits/#{sha}", token: token) : nil
      if commit_data
        msg   = commit_data.dig("commit", "message").to_s.lines.first&.strip
        pusher = commit_data.dig("author", "login") || commit_data.dig("commit", "author", "name")
        latest_commit = { sha: sha[0, 7], message: msg, author: pusher }
      end
    end

    lines = []
    lines << "#{type_icon(type)} <b>#{escape_html(repo)}#{num ? " ##{num}" : ''}</b> · <i>#{escape_html(reason)}</i>"
    lines << "<b>#{rich(title)}</b>"

    if d
      meta = []
      (author = d.dig("user", "login")) && meta << "by #{user_link(author)}"
      (badge = state(type, d)) && meta << badge
      if type == "PullRequest"
        a, x, f = d["additions"], d["deletions"], d["changed_files"]
        meta << "+#{a} −#{x} (#{f} file#{f == 1 ? '' : 's'})" if a && x && f
      end
      lines << meta.join(" · ") unless meta.empty?

      if type == "PullRequest" && d["base"] && d["head"]
        base = d.dig("base", "ref")
        head = d.dig("head", "label") || d.dig("head", "ref")
        lines << "<code>#{escape_html(head)}</code> → <code>#{escape_html(base)}</code>"
      end

      labels = (d["labels"] || []).map { |l| l["name"] }.first(5)
      lines << labels.map { |l| "#{extra_icon('label')} #{escape_html(l)}" }.join("  ") unless labels.empty?

      revs = (d["requested_reviewers"] || []).map { |r| r["login"] }.compact.first(5)
      lines << "#{extra_icon('review')} reviewers: #{revs.map { |r| user_link(r) }.join(', ')}" unless revs.empty?
    end

    if latest_commit
      sha_link = "<a href=\"https://github.com/#{repo}/commit/#{latest_commit[:sha]}\"><code>#{latest_commit[:sha]}</code></a>"
      lines << "" << "🔨 new commit #{sha_link} by #{user_link(latest_commit[:author])}: #{rich(latest_commit[:message])}"
    end

    if lc && lc["body"]
      body = lc["body"].to_s.gsub(/\s+/, " ").strip[0, 240]
      lines << "" << "#{extra_icon('comment')} <b>#{user_link(lc.dig('user', 'login'))}</b>: #{rich(body)}"
    end

    lines << "" << url
    lines.join("\n")
  end

  def keyboard_for(thread_id)
    {
      "inline_keyboard" => [[
        { "text" => "✅ Mark as Done", "callback_data" => "done:#{thread_id}" },
        { "text" => "🔕 Unsubscribe", "callback_data" => "unsub:#{thread_id}" }
      ]]
    }
  end
end
