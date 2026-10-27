# The release step of the image pipeline that forgets the descriptions made by the old prompt, see
# Captain::ImageReading::LegacyDescriptions and script/onelink/IMAGE_PIPELINE_RUNBOOK.md.
namespace :onelink do
  namespace :captain do
    desc 'Image descriptions made before the router and the readers: dry run by default (counts only); ' \
         'APPLY=1 CONFIRM=yes BACKUP_DIR=/dir forgets them (backup first); RESTORE=/file.json CONFIRM=yes puts them back'
    task legacy_image_descriptions: :environment do
      legacy = Captain::ImageReading::LegacyDescriptions.new
      confirmed = ENV['CONFIRM'] == 'yes'

      if ENV['RESTORE'].present?
        abort 'CONFIRM=yes is required to restore' unless confirmed

        puts({ status: 'restored', count: legacy.restore!(ENV.fetch('RESTORE')) }.to_json)
      elsif ENV['APPLY'].present?
        abort 'CONFIRM=yes is required to apply' unless confirmed

        puts({ status: 'forgotten' }.merge(legacy.forget!(backup_dir: ENV.fetch('BACKUP_DIR', nil))).to_json)
      else
        puts({ status: 'dry_run' }.merge(legacy.counts).to_json)
      end
    end
  end
end
