# frozen_string_literal: true

require 'digest'

# Checkpoints belong to their existing financial row. A provider claim is deliberately
# not an exactly-once guarantee: an unknown outcome requires reconciliation by a human.
class Billing::CompletionState # rubocop:disable Metrics/ClassLength
  KEY = 'completion_v1'
  CLAIM_TTL = 5.minutes
  FINAL_STATES = %w[completed skipped needs_review].freeze
  STATES = (FINAL_STATES + %w[pending running blocked]).freeze
  FORMAT = 'sha256-canonical-json-v1'
  INVOICE_STEPS = %w[pdf bcc_invoice payment_url invoice_issued eavr esf dunning_t_minus_2 dunning_t_zero recurring_fallback].freeze
  EVENT_STEPS = %w[payment_confirmed review_task].freeze
  CORE_FIELDS = %w[account_id invoice_number period_start period_end usage_period_month currency plan_key
                   amount_minor base_amount_minor addons_amount_minor ai_dialogs_overage_count ai_dialogs_overage_minor
                   call_minutes_overage_count call_minutes_overage_minor partner_commission_base_minor payer_tax_id
                   payer_legal_name knp_code payment_purpose line_items].freeze

  def self.canonical(value)
    case value
    when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
    when Array then value.map { |item| canonical(item) }
    else value.as_json
    end
  end

  def self.digest(value) = Digest::SHA256.hexdigest(JSON.generate(canonical(value)))

  def self.invoice_core(invoice)
    attributes = invoice.respond_to?(:attributes) ? invoice.attributes : invoice.stringify_keys
    canonical(attributes.slice(*CORE_FIELDS))
  end

  def self.metadata(scope:, context:, steps:)
    digest = self.digest(context)
    {
      KEY => {
        'managed' => true, 'format' => FORMAT, 'scope' => scope, 'input_digest' => digest, 'context' => canonical(context),
        'steps' => steps.index_with do |step|
          { 'operation_key' => "#{scope}:#{step}", 'input_digest' => digest, 'state' => 'pending', 'intent' => step }
        end
      }
    }
  end

  def self.invoice_metadata(account:, profile:, notify:, core:)
    context = invoice_context(account, profile).merge('notify' => notify, 'invoice_core' => invoice_core(core),
                                                      'document_due_on' => core.fetch(:due_on).iso8601)
    result = metadata(scope: "invoice:#{core.fetch(:invoice_number)}", context: context,
                      steps: INVOICE_STEPS)
    result[KEY]['steps']['invoice_issued']['state'] = 'skipped' unless notify
    result
  end

  def self.invoice_context(account, profile)
    target_id = profile.billing_whatsapp_conversation_id
    allowed = [account.id, OwnerFinance::AccessPolicy.workspace_account_id].compact.uniq
    target = Conversation.where(account_id: allowed).find_by(id: target_id) if target_id
    {
      'account_id' => account.id,
      'target' => {
        'id' => target_id, 'account_id' => target&.account_id,
        'inbox_id' => target&.inbox_id, 'contact_id' => target&.contact_id
      },
      'document' => {
        'contract_number' => profile.effective_contract_number.presence || 'Оферта OneLink',
        'supplier_bin' => Billing::Config.bcc_supplier_bin, 'supplier_name' => Billing::Config.bcc_supplier_name,
        'supplier_iban' => Billing::Config.bcc_business_iban, 'supplier_bik' => Billing::Config.bcc_supplier_bik,
        'supplier_kbe' => Billing::Config.bcc_supplier_kbe
      }
    }
  end
  private_class_method :invoice_context

  def self.unfinished(scope)
    steps = "metadata -> '#{KEY}' -> 'steps'"
    required = scope.klass == Billing::Invoice ? INVOICE_STEPS : EVENT_STEPS
    keys = required.map { |name| "'#{name}'" }.join(',')
    # CASE keeps jsonb_each safe for malformed managed rows. Missing built-ins
    # and old formats are selected to hold individually, never to synthesize IO.
    scope.where("metadata -> '#{KEY}' ->> 'managed' = 'true'").where(<<~SQL.squish)
      jsonb_typeof(#{steps}) IS DISTINCT FROM 'object'
      OR metadata -> '#{KEY}' ->> 'format' IS DISTINCT FROM '#{FORMAT}'
      OR NOT (#{steps} ?& ARRAY[#{keys}])
      OR EXISTS (SELECT 1 FROM jsonb_each(CASE WHEN jsonb_typeof(#{steps}) = 'object'
                                           THEN #{steps} ELSE '{}'::jsonb END) AS step
                 WHERE step.value ->> 'state' IN ('pending', 'running', 'blocked'))
    SQL
  end

  def initialize(record)
    @record = record
  end

  def metadata
    value = @record.metadata
    value = value[KEY] if value.is_a?(Hash)
    value.is_a?(Hash) ? value : {}
  end

  def managed? = metadata['managed'] == true
  def context = metadata['context'].is_a?(Hash) ? metadata['context'] : {}

  def step(name)
    steps = metadata['steps']
    value = steps[name] if steps.is_a?(Hash)
    value.is_a?(Hash) ? value : {}
  end

  def valid!(name)
    @record.with_lock { prepare_step!(name) }
  end

  # The only dynamic intent is the next card attempt. Its creation and the
  # attempts counter commit together under the caller's Account/Invoice locks.
  def intend_recurring!(number)
    name = "recurring_charge_#{number}"
    @record.with_lock do
      next false unless valid_envelope?(name)
      next prepare_step!(name) if step(name).present?
      next reject!(name, 'missing_recurring_intent') unless @record.is_a?(Billing::Invoice) && number == @record.recurring_attempts_count + 1

      meta = @record.metadata.deep_dup
      meta[KEY]['steps'][name] = {
        'operation_key' => "#{scope}:#{name}", 'input_digest' => metadata['input_digest'],
        'intent' => name, 'state' => 'pending'
      }
      @record.update!(metadata: meta)
      true
    end
  end

  # The caller may hold earlier locks, but this helper never acquires a Contact,
  # Account or Profile lock after the financial row.
  def local!(name, guard: -> { true }, receipt_guard: ->(_receipt) { true })
    @record.with_lock do
      next false unless prepare_step!(name)
      next reject!(name, 'changed_completion_owner') unless guard.call

      next completed_receipt?(name, &receipt_guard) if step(name)['state'] == 'completed'
      next false if FINAL_STATES.include?(step(name)['state'])

      receipt = yield
      next false unless receipt

      write!(name, 'completed', receipt: receipt)
      true
    end
  end

  def block!(name, reason)
    @record.with_lock do
      next false unless prepare_step!(name)
      next false if FINAL_STATES.include?(step(name)['state'])

      write!(name, 'blocked', reason: reason)
      false
    end
  end

  def hold!(name, reason)
    @record.with_lock do
      reject!(name, reason)
      false
    end
  end

  def claim!(name, configured:, irreversible: true)
    @record.with_lock do
      prepare_recurring_intent!(name)
      next nil unless prepare_step!(name)

      next nil unless claimable?(name, irreversible)
      next nil unless !block_given? || yield

      unless configured
        write!(name, 'blocked', reason: 'pending_configuration')
        next nil
      end

      token = SecureRandom.uuid
      write!(name, 'running', token: token, claimed_at: Time.current.iso8601)
      token
    end
  end

  def finish!(name, token, receipt:, attributes: {})
    @record.with_lock do
      next false unless prepare_step!(name) && owns_claim?(name, token)

      yield if block_given?
      @record.assign_attributes(attributes)
      write!(name, 'completed', receipt: receipt)
      true
    end
  end

  def fail!(name, token, error:, irreversible: true)
    @record.with_lock do
      next false unless prepare_step!(name) && owns_claim?(name, token)

      write!(name, irreversible ? 'needs_review' : 'pending', reason: error.class.name)
      false
    end
  end

  def external!(name, configured:, receipt_attribute:, attributes: {}, guard: -> { true })
    # Existing document IDs are concrete receipts, including legacy rows. They do
    # not grant permission to replay a different missing external operation.
    prepared = prepare_external!(name, configured, receipt_attribute)
    return prepared unless prepared.nil?

    raise 'Billing external IO requires a committed transaction' if ActiveRecord::Base.connection.open_transactions.positive?

    token = claim!(name, configured: configured, &guard)
    return false unless token

    result = yield
    receipt = result.fetch(:receipt).to_s.presence
    raise ArgumentError, 'Missing provider receipt' unless receipt

    finish!(name, token, receipt: { receipt_attribute.to_s => receipt },
                         attributes: attributes.merge(result.fetch(:attributes, {})).merge(receipt_attribute => receipt))
  rescue StandardError => e
    raise unless token

    fail!(name, token, error: e)
  end

  private

  def prepare_external!(name, configured, receipt_attribute)
    @record.reload
    return hold!(name, 'legacy_without_checkpoint') unless managed?
    return false unless valid!(name)
    return adopt_receipt!(name, receipt_attribute) if @record.public_send(receipt_attribute).present?
    return hold!(name, 'legacy_without_checkpoint') unless managed?
    return block!(name, 'pending_configuration') unless configured

    nil
  end

  def completed_receipt?(name)
    receipt = step(name)['receipt']
    return true if receipt.is_a?(Hash) && receipt.present? && (!block_given? || yield(receipt))

    reject!(name, 'missing_or_invalid_completion_receipt')
  end

  def claimable?(name, irreversible)
    current = step(name)
    return false if FINAL_STATES.include?(current['state'])
    return true unless current['state'] == 'running'
    return false if Time.iso8601(current.fetch('claimed_at')) > CLAIM_TTL.ago
    return true unless irreversible

    write!(name, 'needs_review', reason: 'stale_external_claim')
    false
  end

  def adopt_receipt!(name, receipt_attribute)
    @record.with_lock do
      receipt = @record.public_send(receipt_attribute)
      next nil if receipt.blank?

      next false unless prepare_step!(name)
      if step(name)['state'] == 'completed'
        next completed_receipt?(name) { |saved| saved[receipt_attribute.to_s] == receipt || saved['existing_document_id'] == receipt }
      end
      next false if step(name)['state'] == 'needs_review'

      write!(name, 'completed', receipt: { 'existing_document_id' => receipt })
      true
    end
  end

  def owns_claim?(name, token)
    token.present? && step(name)['state'] == 'running' && step(name)['token'] == token
  end

  def scope
    @record.is_a?(Billing::Invoice) ? "invoice:#{@record.invoice_number}" : "event:#{@record.source}:#{@record.bank_reference_id}"
  end

  def prepare_recurring_intent!(name)
    match = name.match(/\Arecurring_charge_([1-3])\z/)
    intend_recurring!(match[1].to_i) if match && step(name).empty?
  end

  def prepare_step!(name)
    return false unless valid_envelope?(name)
    return reject!(name, 'invalid_or_missing_checkpoint') unless checkpoint_valid?(name, step(name))
    return reject!(name, 'invalid_running_checkpoint') unless running_checkpoint_valid?(step(name))

    true
  end

  def running_checkpoint_valid?(value)
    return true unless value['state'] == 'running'
    return false unless value['token'].is_a?(String) && value['token'].present? && value['claimed_at'].is_a?(String)

    Time.iso8601(value['claimed_at'])
    true
  rescue ArgumentError
    false
  end

  def valid_envelope?(name)
    return reject!(name, 'legacy_without_checkpoint') unless managed?
    return reject!(name, 'invalid_completion_envelope') unless envelope_shape_valid?
    return reject!(name, 'changed_completion_core') unless bound_context?

    validate_checkpoints!
  end

  def validate_checkpoints!
    required = @record.is_a?(Billing::Invoice) ? INVOICE_STEPS : EVENT_STEPS
    missing = required.find { |key| !metadata['steps'][key].is_a?(Hash) }
    return reject!(missing, 'missing_builtin_checkpoint') if missing

    invalid = metadata['steps'].find { |key, value| !checkpoint_valid?(key, value) }
    return reject!(invalid.first, 'invalid_checkpoint') if invalid

    true
  end

  def envelope_shape_valid?
    metadata['format'] == FORMAT && metadata['scope'] == scope && metadata['context'].is_a?(Hash) &&
      metadata['input_digest'] == self.class.digest(context) && metadata['steps'].is_a?(Hash)
  end

  def checkpoint_valid?(name, value)
    value.is_a?(Hash) && known_intent?(name) && value['operation_key'] == "#{scope}:#{name}" &&
      value['input_digest'] == metadata['input_digest'] && value['intent'] == name && STATES.include?(value['state'])
  end

  def bound_context?
    @record.is_a?(Billing::Invoice) ? bound_invoice_context? : bound_event_context?
  end

  def bound_invoice_context?
    context['account_id'] == @record.account_id && context['invoice_core'] == self.class.invoice_core(@record) &&
      [true, false].include?(context['notify']) && context['document'].is_a?(Hash)
  end

  def bound_event_context?
    keys = %w[source bank_reference_id amount_minor currency account_id billing_invoice_id]
    context['event_core'] == @record.attributes.slice(*keys) && context['invoice_id'] == @record.billing_invoice_id &&
      context['account_id'] == @record.account_id
  end

  def known_intent?(name)
    if @record.is_a?(Billing::Invoice)
      INVOICE_STEPS.include?(name) || name.match?(/\Arecurring_charge_[1-3]\z/)
    else
      EVENT_STEPS.include?(name)
    end
  end

  def reject!(name, reason)
    meta = @record.metadata.is_a?(Hash) ? @record.metadata.deep_dup : {}
    envelope = meta[KEY].is_a?(Hash) ? meta[KEY] : { 'managed' => false }
    envelope['steps'] = {} unless envelope['steps'].is_a?(Hash)
    old = envelope['steps'][name].is_a?(Hash) ? envelope['steps'][name] : {}
    envelope['steps'][name] = old.except('token', 'claimed_at').merge('state' => 'needs_review', 'reason' => reason)
    meta[KEY] = envelope
    @record.update!(metadata: meta)
    false
  end

  def write!(name, state, **details)
    meta = @record.metadata.deep_dup
    old = meta.fetch(KEY).fetch('steps').fetch(name)
    meta[KEY]['steps'][name] = old.except('token', 'claimed_at', 'reason').merge('state' => state).merge(details.stringify_keys)
    @record.update!(metadata: meta)
  end
end
