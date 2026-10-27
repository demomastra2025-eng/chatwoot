# frozen_string_literal: true

namespace 'onelink:notifications' do
  desc 'Preview or apply visit notification schedule refresh'
  task retime_open: :environment do
    puts Reminders::NotificationsReleaseService.new.retime_open
  end

  desc 'Preview or cancel open notifications of inactive or missing rules'
  task cancel_inactive_rule_reminders: :environment do
    puts Reminders::NotificationsReleaseService.new.cancel_inactive_rule_reminders
  end

  desc 'Preview or apply all future visit steps for one active rule'
  task backfill_rule: :environment do
    puts Reminders::NotificationsReleaseService.new.backfill_rule
  end

  desc 'Preview or resave appointment rules with old notification timing'
  task normalize_rules: :environment do
    puts Reminders::NotificationsReleaseService.new.normalize_rules
  end
end
