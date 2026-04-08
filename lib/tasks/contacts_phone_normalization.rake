# frozen_string_literal: true

namespace :chatwoot do
  namespace :contacts do
    desc 'Dry-run or apply contact phone number normalization. Use APPLY=1 to write changes. Optional ACCOUNT_ID=<id>.'
    task normalize_phone_numbers: :environment do
      apply = ActiveModel::Type::Boolean.new.cast(ENV['APPLY'])
      account_id = ENV['ACCOUNT_ID'].presence

      scope = Contact.where.not(phone_number: [nil, ''])
      scope = scope.where(account_id: account_id) if account_id

      totals = {
        scanned: 0,
        unchanged: 0,
        normalized: 0,
        invalid: 0,
        conflicts: 0
      }

      scope.find_each do |contact|
        totals[:scanned] += 1

        normalized_phone_number = Contacts::PhoneNumberNormalizer.normalize(
          contact.phone_number,
          default_country: contact.send(:phone_number_default_country)
        )

        if normalized_phone_number.blank?
          totals[:invalid] += 1
          next
        end

        if normalized_phone_number == contact.phone_number
          totals[:unchanged] += 1
          next
        end

        conflicting_contact = Contact.where(
          account_id: contact.account_id,
          phone_number: normalized_phone_number
        ).where.not(id: contact.id).pick(:id)

        if conflicting_contact.present?
          totals[:conflicts] += 1
          puts "[conflict] contact=#{contact.id} current=#{contact.phone_number} normalized=#{normalized_phone_number} conflict_with=#{conflicting_contact}"
          next
        end

        totals[:normalized] += 1
        puts "[change] contact=#{contact.id} #{contact.phone_number} -> #{normalized_phone_number}"

        next unless apply

        contact.update_columns(phone_number: normalized_phone_number, updated_at: Time.current)
      end

      puts
      puts "apply=#{apply}"
      puts "account_id=#{account_id || 'all'}"
      totals.each do |key, value|
        puts "#{key}=#{value}"
      end
    end
  end
end
