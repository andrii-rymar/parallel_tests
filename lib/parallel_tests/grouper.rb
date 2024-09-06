# frozen_string_literal: true
module ParallelTests
  class Grouper
    API_TAG = "@api"
    UI_TAG = "@ui"

    class << self
      def by_steps(tests, num_groups, options)
        features_with_steps = group_by_features_with_steps(tests, options)
        in_even_groups_by_size(features_with_steps, num_groups)
      end

      def by_scenarios(tests, num_groups, options = {})
        scenarios = group_by_scenarios(tests, options)
        in_even_groups_by_size(scenarios, num_groups, options)
      end

      def by_scenarios_runtime(tests, num_groups, options = {})
        ui_scenarios_with_size = scenarios_with_size(tests, options.merge(ignore_tag_pattern: API_TAG))
        api_scenarios_with_size = scenarios_with_size(tests, options.merge(ignore_tag_pattern: UI_TAG))

        ui_scenarios_size = partition_size(ui_scenarios_with_size)
        api_scenarios_size = partition_size(api_scenarios_with_size)
        ui_num_groups, api_num_groups = calculate_num_groups(num_groups, ui_scenarios_size, api_scenarios_size)

        puts "UI number: #{ui_num_groups}"
        puts "API number: #{api_num_groups}"

        ui_groups = ui_num_groups > 0 ? in_even_groups_by_size(ui_scenarios_with_size, ui_num_groups, options) : []
        api_groups = api_num_groups > 0 ? in_even_groups_by_size(api_scenarios_with_size, api_num_groups, options) : []

        ui_groups + api_groups
      end

      def in_even_groups_by_size(items, num_groups, options = {})
        groups = Array.new(num_groups) { { items: [], size: 0 } }

        return specify_groups(items, num_groups, options, groups) if options[:specify_groups]

        # add all files that should run in a single process to one group
        single_process_patterns = options[:single_process] || []

        single_items, items = items.partition do |item, _size|
          single_process_patterns.any? { |pattern| item =~ pattern }
        end

        isolate_count = isolate_count(options)

        if isolate_count >= num_groups
          raise 'Number of isolated processes must be >= total number of processes'
        end

        if isolate_count >= 1
          # add all files that should run in a multiple isolated processes to their own groups
          group_features_by_size(items_to_group(single_items), groups[0..(isolate_count - 1)])
          # group the non-isolated by size
          group_features_by_size(items_to_group(items), groups[isolate_count..])
        else
          # add all files that should run in a single non-isolated process to first group
          group_features_by_size(items_to_group(single_items), [groups.first])

          # group all by size
          group_features_by_size(items_to_group(items), groups)
        end

        puts "Estimated groups:"
        groups.each_with_index do |g, i|
          duration_seconds = g[:size].to_i
          duration_human = "%02d:%02d" % [duration_seconds / 60 % 60, duration_seconds % 60]
          puts "##{i+1}: #{g[:items].size} tests, #{duration_human}"
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

      def largest_first(files)
        files.sort_by { |_item, size| size }.reverse
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

      def group_features_by_size(items, groups_to_fill)
        items.each do |item, size|
          size ||= 1
          smallest = smallest_group(groups_to_fill)
          add_to_group(smallest, item, size)
        end
      end

      def items_to_group(items)
        items.first && items.first.size == 2 ? largest_first(items) : items
      end

      def scenarios_with_size(tests, options)
        scenarios = group_by_scenarios(tests, options)
        ParallelTests::Test::Runner.add_size(
          scenarios,
          group_by: :runtime,
          runtime_log: options[:runtime_log],
          allowed_missing_percent: options[:allowed_missing_percent]
        )
      end

      def calculate_num_groups(total_num_groups, partition1_size, partition2_size)
        total_size = partition1_size + partition2_size

        num_groups1 = num_groups(total_num_groups, total_size, partition1_size)
        num_groups2 = num_groups(total_num_groups, total_size, partition2_size)

        if num_groups1 + num_groups2 > total_num_groups
          if num_groups1 > num_groups2
            num_groups1 -= 1
          else
            num_groups2 -= 1
          end
        end

        [num_groups1, num_groups2]
      end

      def partition_size(partition)
        partition.sum { |test| test[1] }
      end

      def num_groups(total_num_groups, total_size, partition_size)
        partition_size > 0 ? [(total_num_groups * (partition_size / total_size)).round, 1].max : 0
      end
    end
  end
end
