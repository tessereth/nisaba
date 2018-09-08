require 'json'
require 'jwt'
require 'sinatra'

module Nisaba
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
      comparison_signature = 'sha1=' + OpenSSL::HMAC.hexdigest(
        OpenSSL::Digest.new('sha1'),
        @config.webhook_secret,
        payload_body
      )
      Rack::Utils.secure_compare(signature, comparison_signature)
    end
  end
end
