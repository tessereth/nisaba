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
    end

    def self.handle(payload)
      @config.handlers.each do |handler|
        handler.handle(payload)
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
        halt 401, "Signatures didn't match!" unless verify_signature(payload_body)

        payload = JSON.parse(params[:payload])
        Nisaba::Application.handle(payload)
      end

      Sinatra::Application.run!
    end

    def self.verify_signature(payload_body)
      signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), @config.webhook_secret, payload_body)
      Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
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
      def handle(payload)
        puts "Reconciling label '#{name}' for payload #{payload}"
      end
    end

    class Comment < Base
      def handle(payload)
        puts "Reconciling comment '#{name}' for payload #{payload}"
      end
    end

    class Review < Base
      def handle(payload)
        puts "Reconciling review '#{name}' for payload #{payload}"
      end
    end
  end
end
