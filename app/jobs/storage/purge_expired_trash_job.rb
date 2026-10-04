# frozen_string_literal: true

class Storage::PurgeExpiredTrashJob < ApplicationJob
  queue_as :housekeeping

  def perform
    Storage::TrashService.purge_expired_all!
  end
end
