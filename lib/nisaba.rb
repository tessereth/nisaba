require 'git_diff'
require 'json'
require 'jwt'
require 'logger'
require 'octokit'
require 'sinatra'

require "nisaba/version"

module Nisaba
  extend self
  extend Forwardable

  def_delegators :'Nisaba::Application', :configure, :run!

  class Application
    def self.configure
      @config ||= Configuration.new
      yield @config
      @config.validate!
    end

    def self.handle(event, payload)
      request_context = RequestContext.new(event: event, payload: payload, config: @config)
      @config.handlers.each do |handler|
        handler.handle(request_context)
      end
    end

    def self.run!
      Sinatra::Application.get '/*' do
        'OK'
      end

      Sinatra::Application.post '/webhook' do
        request.body.rewind
        payload_body = request.body.read
        unless Nisaba::Application.verify_signature(payload_body, request.env['HTTP_X_HUB_SIGNATURE'])
          halt 401, "Signatures didn't match!"
        end

        payload = JSON.parse(payload_body, symbolize_names: true)
        Nisaba::Application.handle(request.env['HTTP_X_GITHUB_EVENT'], payload)
        'OK'
      end

      Sinatra::Application.run!
    end

    def self.verify_signature(payload_body, signature)
      comparison_signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), @config.webhook_secret, payload_body)
      Rack::Utils.secure_compare(signature, comparison_signature)
    end
  end

  class Configuration
    attr_accessor :webhook_secret, :logger, :app_id
    attr_reader :handlers, :app_private_key

    def initialize
      @handlers = []
      @logger = Logger.new(STDOUT)
    end

    def app_private_key=(str)
      @app_private_key = OpenSSL::PKey::RSA.new(str)
    end

    def label(name, &block)
      logger.debug("Managing label '#{name}'")
      handlers << Handler::Label.new(name, block)
    end

    def comment(name)
      logger.debug("Managing comment '#{name}'")
      config = Comment.new
      yield config
      handlers << Handler::Comment.new(name, config)
    end

    def review(name, &block)
      logger.debug("Managing review '#{name}'")
      config = Review.new
      yield config
      handlers << Handler::Review.new(name, config)
    end

    def validate!
      if webhook_secret.nil? || webhook_secret.empty?
        raise ConfigurationError, 'webhook_secret must be set'
      end
      if app_id.nil? || app_id.empty?
        raise ConfigurationError, 'app_id must be set'
      end
      if app_private_key.nil?
        raise ConfigurationError, 'app_private_key must be set'
      end
    end

    class Comment
      attr_reader :when_block, :body_block
      attr_accessor :update_strategy

      def initialize
        @update_strategy = :update
      end

      def when(&block)
        @when_block = block
      end

      def body(&block)
        @body_block = block
      end
    end

    class Review
      attr_reader :when_block, :body_block, :line_comments_block
      attr_accessor :type, :update_strategy

      def initialize
        @type = :comment
        @update_strategy = :never
      end

      def when(&block)
        @when_block = block
      end

      def body(&block)
        @body_block = block
      end

      def line_comments(&block)
        @line_comments_block = block
      end
    end
  end

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
      installation_token = client.create_app_installation_access_token(installation_id, accept: 'application/vnd.github.machine-man-preview+json')[:token]
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

  module Handler
    class Base
      def handle(context)
        return unless filter(context)
        perform(context)
      end

      def filter(_context)
        true
      end

      def perform(_context); end
    end

    class Label < Base
      attr_reader :name, :block

      def initialize(name, block)
        @name = name
        @block = block
      end

      def filter(context)
        context.event == 'pull_request' && !%w[labeled unlabeled].include?(context.payload[:action])
      end

      def perform(context)
        context.logger.info("Reconciling label '#{name}' for '#{context}'")

        label = label_name(context)
        return unless label
        has_label = context.payload.dig(:pull_request, :labels).map { |x| x[:name] }.include?(label)
        if block.call(context)
          if has_label
            context.logger.info("Label '#{label}' already applied")
          else
            context.client.add_labels_to_an_issue(context.repo, context.pr_number, [label])
            context.logger.info("Added label '#{label}'")
          end
        else
          if has_label
            begin
              context.client.remove_label(context.repo, context.pr_number, label)
              context.logger.info("Removed label '#{label}'")
            rescue Octokit::NotFound
              # label isn't there, presumably because someone has bad/good timing deleting it
            end
          else
            context.logger.info("Label '#{label}' already not applied")
          end
        end
      end

      def label_name(context)
        # TODO: consider search api: https://developer.github.com/v3/search/#search-labels
        # TODO: pagination
        # TODO: consider caching
        all_labels = context.client.labels(context. repo).map(&:name)
        matching_labels = all_labels.select { |label| label.include?(name) }

        if matching_labels.empty?
          context.logger.error("Label '#{name}' not found in repository #{context.repo}: found #{all_labels}")
          return
        elsif matching_labels.count > 1
          context.logger.error("Label '#{name}' is ambiguous in repository #{context.repo}: matches #{matching_labels}")
          return
        end

        matching_labels.first
      end
    end

    class Comment < Base
      attr_reader :name, :config

      def initialize(name, config)
        @name = name
        @config = config
      end

      def filter(context)
        context.event == 'pull_request'
      end

      def perform(context)
        context.logger.info("Reconciling comment '#{name}' for '#{context}'")

        current = current_comment(context)
        should_have_comment = config.when_block.call(context)

        if should_have_comment
          body = "#{config.body_block.call(context)}\n\n&nbsp;\n#{id_string}"
          if body == current&.body
            context.logger.debug("Comment remains unchanged")
            return
          end
          if current
            case config.update_strategy
            when :update
              context.logger.debug("Updating comment")
              context.client.update_comment(context.repo, current.id, body)
            when :replace
              context.logger.debug("Deleting old comment and adding new")
              context.client.delete_comment(context.repo, current.id)
              context.client.add_comment(context.repo, context.pr_number, body)
            when :never
              context.logger.debug("Ignoring change due to 'never' update strategy")
            else
              config.logger.error("Unknown update strategy: #{config.update_strategy}")
            end
          else
            context.logger.debug("Adding comment")
            context.client.add_comment(context.repo, context.pr_number, body)
          end
        elsif current
          context.logger.debug("Deleting old comment")
          context.client.delete_comment(context.repo, current.id)
        else
          context.logger.debug("Comment should not apply and does not exist")
        end
      end

      def current_comment(context)
        # TODO: pagination
        comments = context.client.issue_comments(context.repo, context.pr_number)
        comments.each do |comment|
          if comment.body.include?(id_string)
            return comment
          end
        end
        nil
      end

      def id_string
        "_nisaba: '#{name}'_"
      end
    end

    class Review < Base
      attr_reader :name, :config

      def initialize(name, config)
        @name = name
        @config = config
      end

      def filter(context)
        context.event == 'pull_request'
      end

      def perform(context)
        context.logger.info("Reconciling review '#{name}' for '#{context}'")

        current = current_review(context)

        if current
          context.logger.info("Skipping as review already exists and updating is not supported")
          return
        end

        should_have_review = config.when_block.call(context)

        if should_have_review
          params = {
            commit_id: context.payload.dig(:pull_request, :head, :sha),
            body: make_body(context),
            event: config.type.to_s.upcase,
            comments: config.line_comments_block.call(context)
          }
          context.logger.debug("Adding review")
          context.client.create_pull_request_review(context.repo, context.pr_number, params)
        else
          context.logger.debug("Review should not apply and does not exist")
        end
      end

      def current_review(context)
        # TODO: pagination
        reviews = context.client.pull_request_reviews(context.repo, context.pr_number)
        reviews.each do |review|
          if review.body.include?(id_string)
            return review
          end
        end
        nil
      end

      def id_string
        "_nisaba: '#{name}'_"
      end

      def make_body(context)
        [config.body_block.call(context), id_string].compact.join("\n\n&nbsp;\n")
      end
    end
  end

  class ConfigurationError < StandardError; end
end
