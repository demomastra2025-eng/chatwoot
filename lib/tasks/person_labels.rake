# frozen_string_literal: true

namespace :onelink do
  namespace :labels do
    desc 'One-time: give the contact and every conversation of each person the union of the labels the person carries. ' \
         'Dry run (counts only, writes nothing) unless APPLY=1. [ACCOUNT_ID=] [BATCH_SIZE=]'
    task unify_person_union: :environment do
      result = Labels::PersonUnionBackfill.new(
        account_id: ENV.fetch('ACCOUNT_ID', nil),
        apply: ENV['APPLY'] == '1',
        batch_size: ENV.fetch('BATCH_SIZE', Labels::PersonUnionBackfill::DEFAULT_BATCH_SIZE)
      ).perform

      puts JSON.pretty_generate(result)
    end
  end
end
