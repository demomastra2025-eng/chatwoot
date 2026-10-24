# frozen_string_literal: true

# Descriptions of ALL the images of the history that the agent of a reply suggestion receives, never one after another:
# a description that is already cached on the attachment is reused; the rest are made in parallel, at most MAX_CONCURRENCY at a time.
#
# targets: [[attachment, image_url], ...] (see Captain::OpenAiMessageBuilderService#describable_images).
# Returns { attachment_id => description }. Image recognition never raises: it answers with its fallback text when it fails.
class Captain::ReplySuggestion::ImageDescriber
  MAX_CONCURRENCY = 5
  POLL_SECONDS = 0.25

  def initialize(account:, targets:)
    @account = account
    @targets = targets.to_a.uniq { |attachment, _url| attachment.id }
  end

  def perform
    cached, pending = @targets.partition { |attachment, _url| cached_description(attachment).present? }
    descriptions = cached.to_h { |attachment, _url| [attachment.id, cached_description(attachment)] }
    descriptions.merge(describe_in_parallel(pending))
  end

  private

  def cached_description(attachment)
    attachment.meta.to_h[Captain::ImageRecognitionService::CACHE_KEY].to_s.strip.presence
  end

  def describe_in_parallel(pending)
    return {} if pending.empty?

    queue = Queue.new
    pending.each { |target| queue << target }
    results = Concurrent::Map.new
    finished = Queue.new
    scope = Captain::Runtime::Council::ThreadScope.capture
    workers = start_workers(queue, results, finished, scope, pending.size)
    wait_for(workers, pending.size, finished)
    results.keys.index_with { |id| results[id] }
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
  end

  def start_workers(queue, results, finished, scope, count)
    Array.new([MAX_CONCURRENCY, count].min) do
      Thread.new do
        Thread.current.report_on_exception = false
        scope.run { work(queue, results, finished) }
      end
    end
  end

  def work(queue, results, finished)
    while (target = next_target(queue))
      attachment, url = target
      begin
        results[attachment.id] = describe(attachment, url)
      ensure
        finished << attachment.id
      end
    end
  end

  def next_target(queue)
    queue.pop(true)
  rescue ThreadError
    nil
  end

  def describe(attachment, url)
    Captain::ImageRecognitionService.new(account: @account, attachment: attachment, image_url: url).perform
  end

  # The calling thread waits, and keeps honouring the cancel and the deadline of the run while it waits.
  def wait_for(workers, expected, finished)
    done = 0
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
      while done < expected
        done += 1 if finished.pop(timeout: POLL_SECONDS)
        Captain::ReplySuggestion::RunControl.checkpoint!(:images)
        break if workers.none?(&:alive?) && finished.empty?
      end
    end
  end
end
