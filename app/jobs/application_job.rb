class ApplicationJob < ActiveJob::Base
  # https://api.rubyonrails.org/v5.2.1/classes/ActiveJob/Exceptions/ClassMethods.html
  discard_on ActiveJob::DeserializationError do |job, error|
    serialized_arguments = Array.wrap(job.instance_variable_get(:@serialized_arguments))

    Rails.logger.info(
      "Skipping #{job.class} because of ActiveJob::DeserializationError " \
      "(#{error.message}); serialized_argument_count=#{serialized_arguments.size}"
    )
  end
end
