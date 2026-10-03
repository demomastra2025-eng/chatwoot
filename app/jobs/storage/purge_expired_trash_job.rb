# frozen_string_literal: true

class Storage::PurgeExpiredTrashJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Storage::TrashService.purge_expired_all!
  end
end
