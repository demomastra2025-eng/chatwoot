# frozen_string_literal: true

class Accounts::MergeAiUsageService
  def initialize(account:, source:, target:)
    @account = account
    @source = source
    @target = target
  end

  def capture!
    raise ArgumentError, 'Metering merge must stay in one account' unless [@source, @target].all? { |contact| contact.account_id == @account.id }

    @contacts = Contact.where(account_id: @account.id, id: [@source.id, @target.id]).order(:id).lock.to_a
    raise ActiveRecord::RecordNotFound unless @contacts.size == 2

    @snapshots = @contacts.map { |contact| Accounts::AiDialogWindow.new(contact, at: Time.current).snapshot }
    self
  end

  def perform
    seeds = @snapshots.flat_map { |state| Array(state['legacy_seeds']) }
    previous = previous_counts
    transfer_events!
    return if seeds.empty? && previous.empty? && !new_replies?

    state = Accounts::AiDialogState.find_or_initialize_by(account_id: @account.id, contact_id: @target.id)
    state.update!(state: { 'legacy_seeds' => seeds, 'period_counts' => previous })
    Accounts::MonthlyAiUsageService.new(@account).reconcile_ai_dialogs!(@contacts.find { |contact| contact.id == @target.id })
  end

  private

  def previous_counts
    @snapshots.each_with_object(Hash.new(0)) do |state, counts|
      state.fetch('period_counts', {}).each { |period, value| counts[period] += value }
    end
  end

  def transfer_events!
    Accounts::AiUsageEvent.where(account_id: @account.id, contact_id: @source.id)
                          .update_all(contact_id: @target.id) # rubocop:disable Rails/SkipsModelValidations
    Accounts::AiDialogState.where(account_id: @account.id, contact_id: @source.id).delete_all
  end

  def new_replies?
    Accounts::AiUsageEvent.where(account_id: @account.id, contact_id: @target.id,
                                 bucket: Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY).where('quantity > 0').exists?
  end
end
