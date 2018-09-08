# frozen_string_literal: true

module Nisaba
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
  end
end
