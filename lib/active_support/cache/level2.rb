require 'active_support/cache'

require 'active_support/version'
if ActiveSupport::VERSION::MAJOR == 3
  # active_support/cache actually depends on this but doesn't require it:
  require 'securerandom'
end

require "monitor"

module ActiveSupport
  module Cache
    class Level2 < Store
      attr_reader :stores, :store_name

      def initialize(store_options)
        @store_name = store_options.delete(:name) || ''
        @stores = store_options.each_with_object({}) do |(name,options), h|
          h[name] = ActiveSupport::Cache.lookup_store(options)
        end
        provided_namespace = store_options[:namespace]
        store_options[:namespace] = proc do
          provided = provided_namespace.is_a?(Proc) ? provided_namespace.call : ''
          @store_name + ':' + provided
        end
        
        @monitor = Monitor.new
         
        super(store_options)
      end

      def cleanup(*args)
        @stores.each_value { |s| s.cleanup(*args) }
      end

      def clear(*args)
        @stores.each_value { |s| s.clear(*args) }
      end

      def increment(name, amount = 1, options = nil)
        modify_value(name, amount, options)
      end

      def decrement(name, amount = 1, options = nil)
        modify_value(name, -amount, options)
      end
      
      protected

      def read_entry(key, options)
        stores = selected_stores(options)
        read_entry_from(stores, key, options)
      end

      def write_entry(key, entry, options)
        in_each_store(selected_stores(options)) do |name, store|
          record_event(:write, cache_name: name) do
            !!store.send(:write, key, entry, options)
          end
        end
      end

      def delete_entry(key, options)
        selected_stores(options).each do |name, store|
          record_event(:delete, cache_name: name) do
            store.send(:delete, key, options)
          end
        end
      end

      private

      def in_each_store(stores)
        stores.collect do |name, store|
          Thread.new { yield name, store }
        end.map(&:value)
      end

      def read_entry_from(stores, key, options)
        return if stores.empty?

        stores_without_entry = []

        entry = stores.lazy.map do |name, store|
          record_event(:read, cache_name: name) do
            entry = store.send(:read, key, options)
          end

          if entry
            record_event(entry.expired? ? :expired_hit : :hit, cache_name: name)
            entry
          else
            record_event(:miss, cache_name: name)
            stores_without_entry << name
            nil
          end
        end.detect(&:itself)

        return unless entry

        unless stores_without_entry.empty?
          write_entry(key, entry, options.merge(only: stores_without_entry))
        end

        entry
      end

      def record_event(event, cache_name:, &blk)
        ActiveSupport::Notifications.instrument(
          "multi_layer_cache.#{event}",
          {
            store_name: store_name,
            cache_name: cache_name,
            cache: @stores[cache_name]
          },
          &blk
        )
      end

      def selected_stores(options)
        only = options[:only]

        if only.nil?
          @stores
        else
          only = [only] unless only.is_a?(Array)
          @stores.select { |name, _| only.include?(name) }
        end
      end
      
      # Synchronize calls to the cache. This should be called wherever the underlying cache implementation
      # is not thread safe.
      def synchronize(&block) # :nodoc:
        @monitor.synchronize(&block)
      end

      def modify_value(name, amount, options)
        options = merged_options(options)
        synchronize do
          if num = read(name, options)
            num = num.to_i + amount
            write(name, num, options)
            num
          end
        end
      end
    end
  end
end
