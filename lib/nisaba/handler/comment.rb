# frozen_string_literal: true

module Nisaba
  module Handler
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
        resolve(context, current, should_have_comment)
      end

      def resolve(context, current, should_have_comment)
        if should_have_comment
          new_body = "#{config.body_block.call(context)}\n\n&nbsp;\n#{id_string}"
          if new_body == current&.body
            context.logger.debug('Comment remains unchanged')
            return
          end
          if current
            resolve_update(context, current, new_body)
          else
            context.logger.debug('Adding comment')
            context.client.add_comment(context.repo, context.pr_number, new_body)
          end
        elsif current
          context.logger.debug('Deleting old comment')
          context.client.delete_comment(context.repo, current.id)
        else
          context.logger.debug('Comment should not apply and does not exist')
        end
      end

      def resolve_update(context, current, new_body)
        case config.update_strategy
        when :update
          context.logger.debug('Updating comment')
          context.client.update_comment(context.repo, current.id, new_body)
        when :replace
          context.logger.debug('Deleting old comment and adding new')
          context.client.delete_comment(context.repo, current.id)
          context.client.add_comment(context.repo, context.pr_number, new_body)
        when :never
          context.logger.debug("Ignoring change due to 'never' update strategy")
        else
          config.logger.error("Unknown update strategy: #{config.update_strategy}")
        end
      end

      def current_comment(context)
        # TODO: pagination
        comments = context.client.issue_comments(context.repo, context.pr_number)
        comments.each do |comment|
          return comment if comment.body.include?(id_string)
        end
        nil
      end

      def id_string
        "_nisaba: '#{name}'_"
      end
    end
  end
end
