# frozen_string_literal: true

require 'json'

# The descriptions of images made before the router and the two readers: they carry no image_recognition_reader mark. They were made
# by the old prompt («describe the image for a support agent»), which the benchmark of 27.10 showed to invent details on handwriting
# and on small print, and the agent no longer has the pixels to check them against. This is the release step that forgets them, so
# that the next run reads each such image once with the new pipeline.
#
# Only an image that can be read again loses its old description: its file is in the storage, or it has an external link, and it is not
# purged. A description whose image is gone is the only text there is, and stays.
#
#   rake onelink:captain:legacy_image_descriptions                                  # dry run: counts, changes nothing
#   rake onelink:captain:legacy_image_descriptions APPLY=1 CONFIRM=yes BACKUP_DIR=/safe/dir
#   rake onelink:captain:legacy_image_descriptions RESTORE=/safe/dir/legacy-image-descriptions-....json CONFIRM=yes
class Captain::ImageReading::LegacyDescriptions
  CACHE_KEY = Captain::ImageRecognitionService::CACHE_KEY
  READER_KEY = Captain::ImageRecognitionService::READER_KEY
  BACKUP_PREFIX = 'legacy-image-descriptions'

  LEGACY_SQL = <<~SQL.squish
    (attachments.meta ->> '#{CACHE_KEY}') IS NOT NULL AND (attachments.meta ->> '#{READER_KEY}') IS NULL
  SQL

  # The attachments whose old description will be forgotten.
  def candidates
    Attachment.where(file_type: :image).where(LEGACY_SQL).find_each.select { |attachment| readable_again?(attachment) }
  end

  # How many legacy descriptions there are, and how many of them stay because their image cannot be read again.
  def counts
    legacy = Attachment.where(file_type: :image).where(LEGACY_SQL).count
    { legacy: legacy, to_forget: candidates.size }
  end

  # Writes the backup (mode 0600: the descriptions can hold personal data), then forgets the descriptions.
  # Returns { count: the number forgotten, backup: the path of the backup }.
  def forget!(backup_dir:)
    raise ArgumentError, 'BACKUP_DIR is required' if backup_dir.blank?

    rows = candidates
    path = write_backup(rows, backup_dir)
    rows.each { |attachment| attachment.update!(meta: attachment.meta.to_h.except(CACHE_KEY, Captain::ImageRecognitionService::MODEL_KEY)) }
    { count: rows.size, backup: path }
  end

  # Puts the descriptions of a backup back where an image has none now. Returns the number restored.
  def restore!(path)
    JSON.parse(File.read(path)).count do |row|
      attachment = Attachment.find_by(id: row['id'])
      next false if attachment.blank? || attachment.meta.to_h[CACHE_KEY].present?

      attachment.update!(meta: attachment.meta.to_h.merge(CACHE_KEY => row['description']))
      true
    end
  end

  private

  def readable_again?(attachment)
    return false if attachment.file_purged?

    attachment.file.attached? || attachment.external_url.present?
  end

  def write_backup(rows, backup_dir)
    FileUtils.mkdir_p(backup_dir)
    path = File.join(backup_dir, "#{BACKUP_PREFIX}-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.json")
    File.open(path, 'w', 0o600) do |file|
      file.write(JSON.pretty_generate(rows.map { |attachment| { id: attachment.id, description: attachment.meta.to_h[CACHE_KEY] } }))
    end
    path
  end
end
