# frozen_string_literal: true
module ParallelTests
  class Grouper
    BY_SCENARIOS_SUPPORTED_OPTIONS = [:single_process_tag].freeze

    class << self
      def by_steps(tests, num_groups, options)
        features_with_steps = group_by_features_with_steps(tests, options)
        in_even_groups_by_size(features_with_steps, num_groups)
      end

      def by_scenarios(tests, num_groups, options = {})
        scenarios = group_by_scenarios(tests, options)
        in_even_groups_by_size(scenarios, num_groups, options.slice(*BY_SCENARIOS_SUPPORTED_OPTIONS))
      end

      def in_even_groups_by_size(items, num_groups, options = {})
        groups = Array.new(num_groups) { { items: [], size: 0 } }

        return specify_groups(items, num_groups, options, groups) if options[:specify_groups]

        # add all files/scenarios that should run in a single process to one group
        single_items, items = separate_single_items(items, options)

        isolate_count = isolate_count(options)

        if isolate_count >= num_groups
          raise 'Number of isolated processes must be less than total the number of processes'
        end

        if isolate_count >= num_groups
          raise 'Number of isolated processes must be >= total number of processes'
        end

        if isolate_count >= 1
          # add all files that should run in a multiple isolated processes to their own groups
          group_features_by_size(items_to_group(single_items), groups[0..(isolate_count - 1)])
          # group the non-isolated by size
          group_features_by_size(items_to_group(items), groups[isolate_count..-1])
        else
          # add all files that should run in a single non-isolated process to first group
          group_features_by_size(items_to_group(single_items), [groups.first])

          # group all by size
          group_features_by_size(items_to_group(items), groups)
        end

        groups.map! { |g| g[:items].sort }
      end

      private

      def specify_groups(items, num_groups, options, groups)
        specify_test_process_groups = options[:specify_groups].split('|')
        if specify_test_process_groups.count > num_groups
          raise 'Number of processes separated by pipe must be less than or equal to the total number of processes'
        end

        all_specified_tests = specify_test_process_groups.map { |group| group.split(',') }.flatten
        specified_items_found, items = items.partition { |item, _size| all_specified_tests.include?(item) }

        specified_specs_not_found = all_specified_tests - specified_items_found.map(&:first)
        if specified_specs_not_found.any?
          raise "Could not find #{specified_specs_not_found} from --specify-groups in the selected files & folders"
        end

        if specify_test_process_groups.count == num_groups && items.flatten.any?
          raise(
            <<~ERROR
              The number of groups in --specify-groups matches the number of groups from -n but there were other specs
              found in the selected files & folders not specified in --specify-groups. Make sure -n is larger than the
              number of processes in --specify-groups if there are other specs that need to be run. The specs that aren't run:
              #{items.map(&:first)}
            ERROR
          )
        end

        # First order the specify_groups into the main groups array
        specify_test_process_groups.each_with_index do |specify_test_process, i|
          groups[i] = specify_test_process.split(',')
        end

        # Return early when processed specify_groups tests exactly match the items passed in
        return groups if specify_test_process_groups.count == num_groups

        # Now sort the rest of the items into the main groups array
        specified_range = specify_test_process_groups.count..-1
        remaining_groups = groups[specified_range]
        group_features_by_size(items_to_group(items), remaining_groups)
        # Don't sort all the groups, only sort the ones not specified in specify_groups
        sorted_groups = remaining_groups.map { |g| g[:items].sort }
        groups[specified_range] = sorted_groups

        groups
      end

      def isolate_count(options)
        if options[:isolate_count] && options[:isolate_count] > 1
          options[:isolate_count]
        elsif options[:isolate]
          1
        else
          0
        end
      end

      def smallest_group(groups)
        groups.min_by { |g| g[:size] }
      end

      def add_to_group(group, item, size)
        group[:items] << item
        group[:size] += size
      end

      def group_by_features_with_steps(tests, options)
        require 'parallel_tests/cucumber/features_with_steps'
        ParallelTests::Cucumber::FeaturesWithSteps.all(tests, options)
      end

      def group_by_scenarios(tests, options = {})
        require 'parallel_tests/cucumber/scenarios'
        ParallelTests::Cucumber::Scenarios.all(tests, options)
      end

      def separate_single_items(items, options)
        items.partition { |item| single_item?(item, options) }
      end

      def single_item?(item, options)
        if options[:single_process]
          item = item.is_a?(Array) ? item[0] : item
          options[:single_process].any? { |pattern| item =~ pattern }
        elsif options[:single_process_tag]
          item_tags = item[1]
          item_tags.any? { |tag| tag.match?(options[:single_process_tag]) }
        else
          false
        end
      end

      def group_features_by_size(items, groups_to_fill)
        items.each do |item, size|
          size ||= 1
          smallest = smallest_group(groups_to_fill)
          add_to_group(smallest, item, size)
        end
      end

      # prepare tests before placing them into an execution group
      # expecting items of the next types:
      # - items/tests with size: [["", 5], ...]
      # - Gherkin scenarios: [["example.feature:4", ["@tag1", "@tag2"]], ...]
      # - plain strings/locations: ["", ...]
      def items_to_group(items)
        return largest_first(items) if items_with_size?(items)
        return items_without_tags(items) if scenario_items?(items)

        items
      end

      def items_with_size?(items)
        items.any? { |item| item.is_a?(Array) && item[1].is_a?(Numeric) }
      end

      def scenario_items?(items)
        items.any? { |item| item.is_a?(Array) && item[1].is_a?(Array) }
      end

      def largest_first(files)
        files.sort_by { |_item, size| size }.reverse
      end

      def items_without_tags(items)
        items.map(&:first)
      end
    end
  end
end
