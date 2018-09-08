# frozen_string_literal: true

module Nisaba
  module Handler
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
        should_have_label = block.call(context)
        resolve(context, has_label, should_have_label)
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

      def resolve(context, has_label, should_have_label)
        if should_have_label && has_label
          context.logger.info("Label '#{label}' already applied")
        elsif should_have_label && !has_label
          context.client.add_labels_to_an_issue(context.repo, context.pr_number, [label])
          context.logger.info("Added label '#{label}'")
        elsif has_label
          begin
            context.client.remove_label(context.repo, context.pr_number, label)
            context.logger.info("Removed label '#{label}'")
          rescue Octokit::NotFound # rubocop:disable Lint/HandleExceptions
            # label isn't there, presumably because someone has bad/good timing deleting it
          end
        else
          context.logger.info("Label '#{label}' already not applied")
        end
      end
    end
  end
end
