# frozen_string_literal: true

require 'git_diff'
require 'octokit'

module Nisaba
  class RequestContext
    extend Forwardable

    attr_reader :event, :payload, :client

    def_delegators :@config, :logger

    def initialize(event:, payload:, config:)
      @event = event
      @payload = payload
      @config = config
      @client = make_client
    end

    def to_s
      "#<RequestContext event=#{event} repo=#{repo} >"
    end

    def repo
      payload.dig(:repository, :full_name)
    end

    def pr_number
      payload.dig(:pull_request, :number)
    end

    def make_client
      jwt_payload = {
        iat: Time.now.to_i,
        exp: Time.now.to_i + (10 * 60),
        iss: @config.app_id
      }
      jwt = JWT.encode(jwt_payload, @config.app_private_key, 'RS256')
      client = Octokit::Client.new(bearer_token: jwt)

      installation_id = payload.dig(:installation, :id)
      installation_token = client.create_app_installation_access_token(
        installation_id, accept: 'application/vnd.github.machine-man-preview+json'
      )[:token]
      Octokit::Client.new(bearer_token: installation_token)
    end

    def raw_diff
      @_raw_diff ||= @client.pull_request(repo, pr_number, accept: 'application/vnd.github.v3.diff')
    end

    def diff
      @_diff ||= GitDiff.from_string(raw_diff)
    end

    # For renamed files, includes both old and new names
    def files
      diff.files.flat_map { |f| [f.a_path, f.b_path] }.uniq
    end

    def file?(filename)
      files.any? { |f| match_filter?(f, filename) }
    end

    def each_line(file_filter: nil)
      return enum_for(:each_line, file_filter: file_filter) unless block_given?

      diff.files.each do |file|
        next if file_filter && !match_filter?(file.a_path, file_filter) && !match_filter?(file.b_path, file_filter)

        # position is the position as defined by github line comment api:
        #
        # https://developer.github.com/v3/pulls/reviews/#create-a-pull-request-review
        position = 1
        file.hunks.each do |hunk|
          hunk.lines.each do |line|
            yield file, line, position
            position += 1
          end
          # Add one for the hunk definition line
          position += 1
        end
      end
    end

    private

    def match_filter?(to_match, filter)
      if filter.is_a?(Regexp)
        filter.match?(to_match)
      else
        filter == to_match
      end
    end
  end
end
