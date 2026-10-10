# Unsaved native projections expose serializers and pure validators to session JSON.
# All associations used below are explicitly loaded, including missing references.
module Captain::Playground::RecordSnapshots
  SnapshotScope = Struct.new(:records) do
    def find(id)
      records.find { |record| record.id.to_s == id.to_s } || raise(ActiveRecord::RecordNotFound, 'Record is not available')
    end

    def find_by(**attributes)
      records.find { |record| attributes.all? { |key, value| record.public_send(key).to_s == value.to_s } }
    end

    def where(query, value = nil)
      return self.class.new(records.select { |record| query.all? { |key, item| record.public_send(key) == item } }) if query.is_a?(Hash)

      field = { 'LOWER(email) = ?' => :email, 'LOWER(name) = ?' => :name }.fetch(query)
      self.class.new(records.select { |record| record.public_send(field).to_s.downcase == value })
    end

    def limit(value) = self.class.new(records.first(value))
    def first = records.first
    def to_a = records
    def exists?(**attributes) = find_by(**attributes).present?
    def active = self.class.new(records.reject { |record| record.respond_to?(:active) && record.active == false })
    def ordered = self.class.new(records.sort_by { |record| [record.try(:position).to_i, record.id] })
  end
  CHANNEL_CLASSES = {
    'Channel::Api' => Channel::Api, 'Channel::Whatsapp' => Channel::Whatsapp,
    'Channel::WhatsappWeb' => Channel::WhatsappWeb, 'Channel::Telegram' => Channel::Telegram,
    'Channel::TelegramPersonal' => Channel::TelegramPersonal, 'Channel::TwilioSms' => Channel::TwilioSms
  }.freeze

  private

  def load_snapshot_association(record, name, target)
    record.association(name).tap { |association| association.target = target; association.loaded! }
    record
  end

  def native_snapshot(model, record)
    model.new(record.slice(*model.column_names).merge('account_id' => @session.account.id)).tap do |projection|
      load_snapshot_association(projection, :account, @session.account) if model.reflect_on_association(:account)
    end
  end

  def snapshot_inbox
    config = @data.fetch('inbox', {}).merge('id' => @data.fetch('conversation').fetch('inbox_id'))
    klass = CHANNEL_CLASSES[config['channel_type'].presence || 'Channel::Api'] || raise(ArgumentError, 'Unsupported synthetic channel type')
    channel_config = config.fetch('channel', {}).slice('provider', 'medium')
    channel = native_snapshot(klass, channel_config.merge('id' => config['id']))
    channel.message_templates = @data.fetch('channel_templates') if channel.has_attribute?(:message_templates)
    if channel.has_attribute?(:content_templates)
      channel.content_templates = { 'templates' => @data.fetch('channel_templates') }
    end
    Inbox.new(id: config['id'], account_id: @session.account.id, name: config['name'].presence || 'Synthetic channel', channel: channel).tap do |inbox|
      load_snapshot_association(inbox, :account, @session.account)
      load_snapshot_association(inbox, :channel, channel)
    end
  end

  def snapshot_conversation
    native_snapshot(Conversation, @data.fetch('conversation')).tap do |projection|
      load_snapshot_association(projection, :contact, contact_projection(caller))
      load_snapshot_association(projection, :inbox, snapshot_inbox)
    end
  end

  def snapshot_staff
    @data.fetch('staff').map do |record|
      klass = record['type'] == 'AgentBot' ? AgentBot : User
      klass.new(record.slice('id', 'name', 'email'))
    end
  end

  def snapshot_assignment_account
    records = snapshot_staff
    Struct.new(:users, :agent_bots, :teams).new(
      SnapshotScope.new(records.select { |record| record.is_a?(User) }),
      SnapshotScope.new(records.select { |record| record.is_a?(AgentBot) }),
      SnapshotScope.new(@data.fetch('teams').map { |record| Team.new(record.slice('id', 'name')) })
    )
  end

  def snapshot_remindable(kind)
    return snapshot_conversation if kind == 'conversation'

    collection, klass = { 'deal' => ['deals', Crm::Deal], 'task' => ['tasks', Crm::Task],
                          'appointment' => ['appointments', Scheduling::Appointment] }.fetch(kind)
    selected_id = @data.fetch('selection', {})["#{kind}_id"] || @context.state.dig(kind.to_sym, :id)
    raise ArgumentError, "Current #{kind} is not available" if selected_id.blank?

    native_snapshot(klass, record!(collection, selected_id))
  end

  def snapshot_last_message_time(type)
    record = @data.fetch('messages').reject { |message| message['private'] }.select { |message| message['message_type'] == type.to_s }
                  .max_by { |message| [message['created_at'].to_s, message['id'].to_i] }
    Time.iso8601(record['created_at']) if record&.fetch('created_at', nil).present?
  end

  def snapshot_attachments
    raise ArgumentError, 'Real signed attachments are unavailable in the synthetic workspace' if Array(@args['attachment_ids']).any?

    Array(@args['artifact_ids']).map do |artifact|
      match = /\Atrial_#{Regexp.escape(@session.id)}_document_(\d+)\z/.match(artifact.to_s)
      record = match && @data.fetch('knowledge_documents').find do |item|
        item['id'] == match[1].to_i && item['sendable'] == true && item['visible'] != false && item['available'] != false
      end
      raise ArgumentError, 'Synthetic document artifact is not available in this session' unless record

      artifact
    end
  end

  def snapshot_reminder(record, remindable: nil)
    remindable ||= snapshot_remindable(record.fetch('remindable_kind', 'conversation'))
    native_snapshot(Reminder, record).tap do |projection|
      load_snapshot_association(projection, :remindable, remindable)
      load_snapshot_association(projection, :conversation, snapshot_conversation)
      load_snapshot_association(projection, :target_conversation, snapshot_conversation)
      load_snapshot_association(projection, :target_inbox, snapshot_inbox)
      load_snapshot_association(projection, :target_contact, contact_projection(caller))
      %i[target_contact_inbox creator owner reminder_group].each { |name| load_snapshot_association(projection, name, nil) }
      message_times = %i[incoming outgoing].index_with { |type| snapshot_last_message_time(type) }
      projection.define_singleton_method(:last_conversation_message_at) { |type| message_times[type.to_sym] }
    end
  end

  def snapshot_delivery_policy(content_kind:, template_params:, attachments:, private_note: false, scheduled_at: nil)
    Outbound::DeliveryPolicy.ensure!(conversation: snapshot_conversation, inbox: snapshot_inbox, content_kind: content_kind,
                                     template_params: template_params, attachments: attachments, private_note: private_note,
                                     scheduled_at: scheduled_at, last_incoming_message_at: snapshot_last_message_time(:incoming))
  end
end
