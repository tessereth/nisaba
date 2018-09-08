require 'logger'

module Nisaba
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
end
