require 'rails_helper'

RSpec.describe AutomationRules::ConditionsFilterService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:email_channel) { create(:channel_email, account: account) }
  let(:email_inbox) { create(:inbox, channel: email_channel, account: account) }
  let(:message) do
    create(:message, account: account, conversation: conversation, content: 'test text', inbox: conversation.inbox, message_type: :incoming)
  end
  let(:rule) { create(:automation_rule, account: account) }

  before do
    conversation = create(:conversation, account: account)
    conversation.contact.update(phone_number: '+918484828282', email: 'test@test.com')
    create(:conversation, account: account)
    create(:conversation, account: account)
  end

  describe '#perform' do
    context 'when conditions based on filter_operator equal_to' do
      before do
        rule.conditions = [{ 'values': ['open'], 'attribute_key': 'status', 'query_operator': nil, 'filter_operator': 'equal_to' }]
        rule.save
      end

      context 'when conditions in rule matches with object' do
        it 'will return true' do
          expect(described_class.new(rule, conversation, { changed_attributes: { status: [nil, 'open'] } }).perform).to be(true)
        end
      end

      context 'when conditions in rule does not match with object' do
        it 'will return false' do
          conversation.update(status: 'resolved')
          expect(described_class.new(rule, conversation, { changed_attributes: { status: %w[open resolved] } }).perform).to be(false)
        end
      end
    end

    context 'when conditions based on filter_operator start_with' do
      before do
        contact = conversation.contact
        contact.update(phone_number: '+918484848484')
        rule.conditions = [
          { 'values': ['+918484'], 'attribute_key': 'phone_number', 'query_operator': 'OR', 'filter_operator': 'starts_with' },
          { 'values': ['test'], 'attribute_key': 'email', 'query_operator': nil, 'filter_operator': 'contains' }
        ]
        rule.save
      end

      context 'when conditions in rule matches with object' do
        it 'will return true' do
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(true)
        end
      end

      context 'when conditions in rule does not match with object' do
        it 'will return false' do
          conversation.contact.update(phone_number: '+918585858585')
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(false)
        end
      end
    end

    context 'when conditions based on messages attributes' do
      context 'when filter_operator is equal_to' do
        before do
          rule.conditions = [
            { 'values': ['test text'], 'attribute_key': 'content', 'query_operator': 'AND', 'filter_operator': 'equal_to' },
            { 'values': ['incoming'], 'attribute_key': 'message_type', 'query_operator': nil, 'filter_operator': 'equal_to' }
          ]
          rule.save
        end

        it 'will return true when conditions matches' do
          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(true)
        end

        it 'will return false when conditions in rule does not match' do
          message.update!(message_type: :outgoing)
          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(false)
        end
      end

      context 'when filtering private notes' do
        before do
          rule.conditions = [
            { 'values': [true], 'attribute_key': 'private_note', 'query_operator': nil, 'filter_operator': 'equal_to' }
          ]
          rule.save
        end

        it 'will return true when the message is a private note' do
          message.update!(private: true)

          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(true)
        end

        it 'will return false when the message is not a private note' do
          message.update!(private: false)

          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(false)
        end
      end

      context 'when filter_operator is on processed_message_content' do
        before do
          rule.conditions = [
            { 'values': ['help'], 'attribute_key': 'content', 'query_operator': 'AND', 'filter_operator': 'contains' },
            { 'values': ['incoming'], 'attribute_key': 'message_type', 'query_operator': nil, 'filter_operator': 'equal_to' }
          ]
          rule.save
        end

        let(:conversation) { create(:conversation, account: account, inbox: email_inbox) }
        let(:message) do
          create(:message, account: account, conversation: conversation, content: "We will help you\n\n\n test",
                           inbox: conversation.inbox, message_type: :incoming,
                           content_attributes: { email: { text_content: { quoted: 'We will help you' } } })
        end

        it 'will return true for processed_message_content matches' do
          message
          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(true)
        end

        it 'will return false when processed_message_content does no match' do
          rule.update(conditions: [{ 'values': ['text'], 'attribute_key': 'content', 'query_operator': nil, 'filter_operator': 'contains' }])

          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(false)
        end
      end

      context 'when filtering messages based on conversation attributes' do
        let(:conversation) { create(:conversation, account: account, status: :open, priority: :high) }
        let(:message) do
          create(:message, account: account, conversation: conversation, content: 'Test message',
                           inbox: conversation.inbox, message_type: :incoming)
        end

        it 'will return true when conversation status matches' do
          rule.update(conditions: [{ 'values': ['open'], 'attribute_key': 'status', 'query_operator': nil, 'filter_operator': 'equal_to' }])
          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(true)
        end

        it 'will return false when conversation status does not match' do
          rule.update(conditions: [{ 'values': ['resolved'], 'attribute_key': 'status', 'query_operator': nil, 'filter_operator': 'equal_to' }])
          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(false)
        end

        it 'will return true when conversation priority matches' do
          rule.update(conditions: [{ 'values': ['high'], 'attribute_key': 'priority', 'query_operator': nil, 'filter_operator': 'equal_to' }])
          expect(described_class.new(rule, conversation, { message: message, changed_attributes: {} }).perform).to be(true)
        end
      end
    end

    context 'when conditions based on labels' do
      before do
        conversation.add_labels(['bug'])
      end

      context 'when filter_operator is equal_to' do
        before do
          rule.conditions = [
            { 'values': ['bug'], 'attribute_key': 'labels', 'query_operator': nil, 'filter_operator': 'equal_to' }
          ]
          rule.save
        end

        it 'will return true when conversation has the label' do
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(true)
        end

        it 'will return false when conversation does not have the label' do
          rule.conditions = [
            { 'values': ['feature'], 'attribute_key': 'labels', 'query_operator': nil, 'filter_operator': 'equal_to' }
          ]
          rule.save
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(false)
        end
      end

      context 'when filter_operator is not_equal_to' do
        before do
          rule.conditions = [
            { 'values': ['feature'], 'attribute_key': 'labels', 'query_operator': nil, 'filter_operator': 'not_equal_to' }
          ]
          rule.save
        end

        it 'will return true when conversation does not have the label' do
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(true)
        end

        it 'will return false when conversation has the label' do
          conversation.add_labels(['feature'])
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(false)
        end
      end

      context 'when filter_operator is is_present' do
        before do
          rule.conditions = [
            { 'values': [], 'attribute_key': 'labels', 'query_operator': nil, 'filter_operator': 'is_present' }
          ]
          rule.save
        end

        it 'will return true when conversation has any labels' do
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(true)
        end

        it 'will return false when conversation has no labels' do
          conversation.update_labels([])
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(false)
        end
      end

      context 'when filter_operator is is_not_present' do
        before do
          rule.conditions = [
            { 'values': [], 'attribute_key': 'labels', 'query_operator': nil, 'filter_operator': 'is_not_present' }
          ]
          rule.save
        end

        it 'will return false when conversation has any labels' do
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(false)
        end

        it 'will return true when conversation has no labels' do
          conversation.update_labels([])
          expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(true)
        end
      end
    end

    context 'when conditions based on contact country_code' do
      before do
        conversation.update(additional_attributes: { country_code: 'US' })
        conversation.contact.update(additional_attributes: { country_code: 'IN' })
        rule.conditions = [
          { 'values': ['IN'], 'attribute_key': 'country_code', 'query_operator': nil, 'filter_operator': 'equal_to' }
        ]
        rule.save
      end

      it 'matches against the contact additional_attributes' do
        expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(true)
      end

      it 'returns false when the contact country_code does not match' do
        conversation.contact.update(additional_attributes: { country_code: 'GB' })
        expect(described_class.new(rule, conversation, { changed_attributes: {} }).perform).to be(false)
      end
    end

    context 'when conditions are based on the contact (contact_id)' do
      let(:contact) { conversation.contact }
      let(:other_conversation) { create(:conversation, account: account) }
      let(:other_contact) { other_conversation.contact }

      def contact_condition(operator, values, query_operator: nil)
        { attribute_key: 'contact_id', filter_operator: operator, values: values, query_operator: query_operator }
      end

      def contact_rule(*conditions)
        create(:automation_rule, account: account, conditions: conditions)
      end

      def perform(rule, target = conversation, **options)
        described_class.new(rule, target, { changed_attributes: {} }.merge(options)).perform
      end

      it 'matches only the conversations of the listed contacts with equal_to' do
        rule = contact_rule(contact_condition('equal_to', [contact.id]))

        expect(perform(rule)).to be(true)
        expect(perform(rule, other_conversation)).to be(false)
        expect(perform(contact_rule(contact_condition('equal_to', [other_contact.id, contact.id.to_s])))).to be(true)
      end

      it 'skips the listed contacts with not_equal_to' do
        rule = contact_rule(contact_condition('not_equal_to', [contact.id]))

        expect(perform(rule)).to be(false)
        expect(perform(rule, other_conversation)).to be(true)
        expect(perform(contact_rule(contact_condition('not_equal_to', [other_contact.id, contact.id])))).to be(false)
      end

      it 'treats a conversation without a contact as outside every listed contact' do
        conversation.update_columns(contact_id: nil) # rubocop:disable Rails/SkipsModelValidations

        expect(perform(contact_rule(contact_condition('equal_to', [other_contact.id])))).to be(false)
        expect(perform(contact_rule(contact_condition('not_equal_to', [other_contact.id])))).to be(true)
      end

      it 'combines with other conditions through AND' do
        rule = contact_rule(
          contact_condition('not_equal_to', [other_contact.id], query_operator: 'AND'),
          { attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil }
        )

        expect(perform(rule)).to be(true)

        conversation.update!(status: 'resolved')

        expect(perform(rule)).to be(false)
      end

      it 'combines with other conditions through OR' do
        rule = contact_rule(
          contact_condition('equal_to', [other_contact.id], query_operator: 'OR'),
          { attribute_key: 'status', filter_operator: 'equal_to', values: ['resolved'], query_operator: nil }
        )

        expect(perform(rule)).to be(false)

        conversation.update!(status: 'resolved')

        expect(perform(rule)).to be(true)

        rule = contact_rule(
          { attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: 'OR' },
          contact_condition('not_equal_to', [contact.id])
        )
        conversation.update!(status: 'resolved')

        expect(perform(rule)).to be(false)
      end

      it 'applies to message events through the conversation contact' do
        rule = contact_rule(contact_condition('not_equal_to', [contact.id]))

        expect(perform(rule, conversation, message: message)).to be(false)

        rule = contact_rule(contact_condition('not_equal_to', [other_contact.id]))

        expect(perform(rule, conversation, message: message)).to be(true)
      end

      it 'ignores ids of contacts of another account and of deleted contacts' do
        foreign = create(:contact, account: create(:account))
        deleted = create(:contact, account: account)
        deleted_id = deleted.id
        deleted.destroy!
        rule = contact_rule(contact_condition('equal_to', [contact.id]))

        { 'equal_to' => false, 'not_equal_to' => true }.each do |operator, expected|
          rule.conditions = [contact_condition(operator, [foreign.id, deleted_id])]

          expect(perform(rule)).to eq(expected)
        end

        rule.conditions = [contact_condition('equal_to', [foreign.id, contact.id])]

        expect(perform(rule)).to be(true)
      end

      it 'never matches an unreadable list or an unsupported operator' do
        rule = contact_rule(contact_condition('equal_to', [contact.id]))
        operators = %w[equal_to not_equal_to]

        [[], ['abc'], [nil], [contact.id.to_f.to_s]].each do |values|
          operators.each do |operator|
            rule.conditions = [contact_condition(operator, values)]

            expect(perform(rule)).to be(false)
          end
        end

        rule.conditions = [contact_condition('contains', [contact.id])]

        expect(perform(rule)).to be(false)
      end

      it 'keeps a custom attribute called contact_id working as a custom attribute' do
        create(:custom_attribute_definition, account: account, attribute_key: 'contact_id', attribute_model: :contact_attribute,
                                             attribute_display_type: :text)
        contact.update!(custom_attributes: { 'contact_id' => 'ref-7' })
        rule = contact_rule(
          { attribute_key: 'contact_id', filter_operator: 'equal_to', values: ['ref-7'], query_operator: nil,
            custom_attribute_type: 'contact_attribute' }
        )

        expect(perform(rule)).to be(true)
        expect(perform(rule, other_conversation)).to be(false)
      end
    end
  end
end
