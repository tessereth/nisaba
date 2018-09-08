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
      @config.handlers.each do |handler|
        handler.handle(event, payload)
      end
    end

    def self.run!
      Sinatra::Application.get '/*' do
        # TODO: remove
        Nisaba::Application.handle(test: :data)
        'OK'
      end

      Sinatra::Application.post '/webhook' do
        request.body.rewind
        payload_body = request.body.read
        unless Nisaba::Application.verify_signature(payload_body, request.env['HTTP_X_HUB_SIGNATURE'])
          halt 401, "Signatures didn't match!"
        end

        payload = JSON.parse(payload_body)
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
    attr_accessor :api_token, :webhook_secret, :handlers

    def initialize
      self.handlers = []
    end

    def label(name, &block)
      puts "Managing label '#{name}'"
      handlers << Handler::Label.new(name, block)
    end

    def comment(name, &block)
      puts "Managing comment '#{name}'"
      handlers << Handler::Comment.new(name, block)
    end

    def review(name, &block)
      puts "Managing review '#{name}'"
      handlers << Handler::Review.new(name, block)
    end

    def validate!
      if webhook_secret.nil? || webhook_secret.empty?
        raise ConfigurationError, 'webhook_secret must be set'
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
    end

    class Label < Base
      def handle(event, payload)
        puts "Reconciling label '#{name}' for '#{event}' event with payload #{payload.keys}"
      end
    end

    class Comment < Base
      def handle(event, payload)
        puts "Reconciling comment '#{name}' for '#{event}' event with payload #{payload.keys}"
      end
    end

    class Review < Base
      def handle(event, payload)
        puts "Reconciling review '#{name}' for '#{event}' event with payload #{payload.keys}"
      end
    end
  end

  class ConfigurationError < StandardError; end
end
