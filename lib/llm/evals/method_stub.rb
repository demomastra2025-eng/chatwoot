# frozen_string_literal: true

module Llm
  module Evals
    module MethodStub
      class << self
        def with_many(stubs, &block)
          return block.call if stubs.blank?

          stub = stubs.first
          with(stub.fetch(:target), stub.fetch(:method), stub[:callable]) do
            with_many(stubs.drop(1), &block)
          end
        end

        def with(target, method_name, callable = nil, &block)
          replacement = callable || block
          raise ArgumentError, 'replacement callable is required' unless replacement

          singleton = target.singleton_class
          previous =
            if singleton.method_defined?(method_name) || singleton.private_method_defined?(method_name)
              singleton.instance_method(method_name)
            end

          singleton.send(:define_method, method_name, &replacement)
          yield
        ensure
          singleton.send(:remove_method, method_name) rescue nil
          singleton.send(:define_method, method_name, previous) if previous
        end
      end
    end
  end
end
