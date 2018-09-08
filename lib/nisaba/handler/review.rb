module Nisaba
  module Handler
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
end
