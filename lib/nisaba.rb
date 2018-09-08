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

    def comment(name, &block)
      logger.debug("Managing comment '#{name}'")
      handlers << Handler::Comment.new(name, block)
    end

    def review(name, &block)
      logger.debug("Managing review '#{name}'")
      handlers << Handler::Review.new(name, block)
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
      if filename.is_a?(Regexp)
        files.any? { |f| f.match?(filename) }
      else
        files.any? { |f| f == filename }
      end
    end
  end

  module Handler
    class Base
      attr_reader :name, :block

      def initialize(name, block)
        @name = name
        @block = block
      end

      def handle(context)
        return unless filter(context)
        perform(context)
      end
    end

    class Label < Base
      def filter(context)
        context.event == 'pull_request' && !%w[labeled unlabeled].include?(context.payload[:action])
      end

      def perform(context)
        context.logger.info("Reconciling label '#{name}' for '#{context}'")

        label = label_name(context)
        return unless label
        if block.call(context)
          context.client.add_labels_to_an_issue(context.repo, context.pr_number, [label])
          context.logger.info("Added label '#{label}'")
        else
          begin
            context.client.remove_label(context.repo, context.pr_number, label)
            context.logger.info("Removed label '#{label}'")
          rescue Octokit::NotFound
            # label isn't there so nothing to remove
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
      def handle(context)
        context.logger.info("Reconciling comment '#{name}' for '#{context}'")
      end
    end

    class Review < Base
      def handle(context)
        context.logger.info("Reconciling review '#{name}' for '#{context}'")
      end
    end
  end

  class ConfigurationError < StandardError; end
end
