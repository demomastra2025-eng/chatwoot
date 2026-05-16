class Captain::ToolRegistry
  class Definition
    ATTRIBUTES = %i[
      id
      title
      description
      group_name
      icon
      allowed_scopes
      capability_tool
      agent_tool_class
      assistant_tool_class
      required_features
      required_integrations
      required_permissions
      risk_level
      requires_confirmation
      idempotent
      selected_by_default
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(**attributes)
      attributes = attributes.symbolize_keys

      @id = attributes.fetch(:id)
      @title = attributes.fetch(:title)
      @description = attributes.fetch(:description)
      @group_name = attributes[:group_name]
      @icon = attributes[:icon]
      @allowed_scopes = Array(attributes.fetch(:allowed_scopes)).map(&:to_s).freeze
      @capability_tool = ActiveModel::Type::Boolean.new.cast(attributes[:capability_tool])
      @agent_tool_class = attributes[:agent_tool_class]
      @assistant_tool_class = attributes[:assistant_tool_class]
      @required_features = Array(attributes[:required_features]).map(&:to_s).freeze
      @required_integrations = Array(attributes[:required_integrations]).map(&:to_s).freeze
      @required_permissions = Array(attributes[:required_permissions]).map(&:to_s).freeze
      @risk_level = attributes[:risk_level].presence || 'medium'
      @requires_confirmation = ActiveModel::Type::Boolean.new.cast(attributes[:requires_confirmation])
      @idempotent = ActiveModel::Type::Boolean.new.cast(attributes[:idempotent])
      @selected_by_default = if attributes.key?(:selected_by_default)
                               ActiveModel::Type::Boolean.new.cast(attributes[:selected_by_default])
                             else
                               true
                             end
    end

    def supports_scope?(scope_name)
      allowed_scopes.include?(scope_name.to_s)
    end

    def tool_class_for(scope_name)
      case scope_name.to_s
      when Captain::ToolAccess::SCOPE_AGENT
        agent_tool_class
      when Captain::ToolAccess::SCOPE_ASSISTANT
        assistant_tool_class
      end
    end

    def to_h
      {
        id: id,
        title: title,
        description: description,
        group_name: group_name,
        icon: icon,
        allowed_scopes: allowed_scopes,
        capability_tool: capability_tool,
        required_features: required_features,
        required_integrations: required_integrations,
        required_permissions: required_permissions,
        risk_level: risk_level,
        requires_confirmation: requires_confirmation,
        idempotent: idempotent,
        selected_by_default: selected_by_default,
        custom: false
      }
    end
  end

  class << self
    def definitions
      @definitions ||= [
        definition(
          id: 'search_documentation',
          title: 'Search documentation',
          description: 'Search and retrieve documentation from knowledge base',
          group_name: 'Knowledge',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::SearchDocumentationService,
          risk_level: 'low'
        ),
        definition(
          id: 'list_captain_documents',
          title: 'List Captain Documents',
          description: 'List Captain knowledge documents and safe artifact IDs for files that can be attached to messages',
          group_name: 'Knowledge',
          icon: 'document',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::ListCaptainDocumentsService,
          risk_level: 'low'
        ),
        definition(
          id: 'faq_lookup',
          title: 'FAQ Lookup',
          description: 'Search FAQ responses using semantic similarity to find relevant answers',
          group_name: 'Knowledge',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          capability_tool: true,
          agent_tool_class: Captain::Tools::FaqLookupTool,
          assistant_tool_class: Captain::Tools::Copilot::FaqLookupService,
          risk_level: 'low'
        ),
        definition(
          id: 'add_contact_note',
          title: 'Add Contact Note',
          description: 'Add a note to the current conversation contact',
          group_name: 'Conversations',
          icon: 'note-add',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          capability_tool: true,
          agent_tool_class: Captain::Tools::AddContactNoteTool,
          assistant_tool_class: Captain::Tools::Copilot::AddContactNoteService,
          required_permissions: %w[contact_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'add_private_note',
          title: 'Add Private Note',
          description: 'Add a private note to the current conversation',
          group_name: 'Conversations',
          icon: 'eye-off',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          capability_tool: true,
          agent_tool_class: Captain::Tools::AddPrivateNoteTool,
          assistant_tool_class: Captain::Tools::Copilot::AddPrivateNoteService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'add_label_to_conversation',
          title: 'Add Label to Conversation',
          description: 'Add an existing label to the current conversation',
          group_name: 'Conversations',
          icon: 'tag',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::AddLabelToConversationTool,
          assistant_tool_class: Captain::Tools::Copilot::AddLabelToConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'update_priority',
          title: 'Update Priority',
          description: 'Update the priority of the current conversation',
          group_name: 'Conversations',
          icon: 'exclamation-triangle',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdatePriorityTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdatePriorityService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'resolve_conversation',
          title: 'Resolve Conversation',
          description: 'Resolve the current conversation when the issue has been addressed or the conversation should be closed',
          group_name: 'Conversations',
          icon: 'checkmark',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ResolveConversationTool,
          assistant_tool_class: Captain::Tools::Copilot::ResolveConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'handoff',
          title: 'Handoff to Human',
          description: 'Hand off the current conversation to a human team',
          group_name: 'Conversations',
          icon: 'user-switch',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          capability_tool: true,
          agent_tool_class: Captain::Tools::HandoffTool,
          assistant_tool_class: Captain::Tools::Copilot::HandoffService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'cancel_response',
          title: 'Cancel Response',
          description: 'Silently stop the current AI response when no customer reply should be sent',
          group_name: 'Conversations',
          icon: 'stop-circle',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          capability_tool: true,
          agent_tool_class: Captain::Tools::CancelResponseTool,
          assistant_tool_class: Captain::Tools::Copilot::CancelResponseService,
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'send_notification',
          title: 'Send Notification',
          description: 'Send an in-app notification to an account user about the current or specified conversation',
          group_name: 'Conversations',
          icon: 'bell',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          capability_tool: true,
          agent_tool_class: Captain::Tools::SendNotificationTool,
          assistant_tool_class: Captain::Tools::Copilot::SendNotificationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_conversation',
          title: 'Get Conversation',
          description: 'Get details of a conversation including messages and contact information',
          group_name: 'Conversations',
          icon: 'chat',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'low'
        ),
        definition(
          id: 'search_conversations',
          title: 'Search Conversations',
          description: 'Search conversations by status, priority, contact, or labels',
          group_name: 'Conversations',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchConversationsService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'low'
        ),
        definition(
          id: 'get_contact',
          title: 'Get Contact',
          description: 'Get details of a contact including profile information',
          group_name: 'Contacts',
          icon: 'user',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetContactService,
          required_permissions: %w[contact_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_contacts',
          title: 'Search Contacts',
          description: 'Search contacts by name, email, or phone number',
          group_name: 'Contacts',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchContactsService,
          required_permissions: %w[contact_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'create_contact',
          title: 'Create Contact',
          description: 'Create a new account contact by email, phone number, or identifier',
          group_name: 'Contacts',
          icon: 'user-add',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::CreateContactService,
          required_permissions: %w[contact_manage],
          risk_level: 'medium',
          idempotent: true
        ),
        definition(
          id: 'update_contact',
          title: 'Update Contact',
          description: 'Update the current conversation contact',
          group_name: 'Contacts',
          icon: 'user-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateContactTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateContactService,
          required_permissions: %w[contact_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_company',
          title: 'Get Company',
          description: 'Get details of a company',
          group_name: 'Companies',
          icon: 'briefcase',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetCompanyService,
          risk_level: 'low'
        ),
        definition(
          id: 'search_companies',
          title: 'Search Companies',
          description: 'Search companies by name or domain',
          group_name: 'Companies',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchCompaniesService,
          risk_level: 'low'
        ),
        definition(
          id: 'create_company',
          title: 'Create Company',
          description: 'Create a company for the current conversation contact',
          group_name: 'Companies',
          icon: 'briefcase',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateCompanyTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateCompanyService,
          required_permissions: %w[contact_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'update_company',
          title: 'Update Company',
          description: 'Update the company linked to the current conversation contact',
          group_name: 'Companies',
          icon: 'briefcase-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateCompanyTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateCompanyService,
          required_permissions: %w[contact_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_deal',
          title: 'Get Deal',
          description: 'Get details of a CRM deal',
          group_name: 'CRM Deals',
          icon: 'money',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetDealService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_deals',
          title: 'Search Deals',
          description: 'Search CRM deals by title, pipeline, stage, owner, or company',
          group_name: 'CRM Deals',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchDealsService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'list_deal_pipelines',
          title: 'List Deal Pipelines',
          description: 'List active CRM deal pipelines with ordered stages and stage IDs. Use before creating or moving deals.',
          group_name: 'CRM Deals',
          icon: 'table',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::ListDealPipelinesService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'list_deal_stages',
          title: 'List Deal Stages',
          description: 'List ordered CRM deal stages for a pipeline/current deal with previous and next stage IDs.',
          group_name: 'CRM Deals',
          icon: 'list',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::ListDealStagesService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'list_deal_custom_fields',
          title: 'List Deal Custom Fields',
          description: 'List active allowed CRM custom fields for deal custom_attributes with key, label, type, required flag, and select options',
          group_name: 'CRM Deals',
          icon: 'custom-field',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ListDealCustomFieldsTool,
          assistant_tool_class: Captain::Tools::Copilot::ListDealCustomFieldsService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'get_deal_timeline',
          title: 'Get Deal Timeline',
          description: 'Get the timeline for a CRM deal',
          group_name: 'CRM Deals',
          icon: 'history',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetDealTimelineService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_view crm_deal_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'create_deal',
          title: 'Create Deal',
          description: 'Create a CRM deal from current conversation context; supports pipeline_id/pipeline_code/stage_id from CRM pipeline catalog',
          group_name: 'CRM Deals',
          icon: 'money',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateDealTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateDealService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'update_deal',
          title: 'Update Deal',
          description: 'Update the CRM deal linked to current conversation; can move to a pipeline-aware stage using stage_id or pipeline-scoped stage code/name',
          group_name: 'CRM Deals',
          icon: 'money-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateDealTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateDealService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'transition_deal_stage',
          title: 'Transition Deal Stage',
          description: 'Move current conversation deal by stage_id or stage_action next/previous within the current pipeline position order',
          group_name: 'CRM Deals',
          icon: 'arrow-right',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::TransitionDealStageTool,
          assistant_tool_class: Captain::Tools::Copilot::TransitionDealStageService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_manage],
          risk_level: 'high'
        ),
        definition(
          id: 'add_deal_comment',
          title: 'Add Deal Comment',
          description: 'Add a comment to the CRM deal linked to the current conversation',
          group_name: 'CRM Deals',
          icon: 'comment',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::AddDealCommentService,
          required_features: %w[crm_deals],
          required_permissions: %w[crm_deal_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_task',
          title: 'Get Task',
          description: 'Get details of a CRM task',
          group_name: 'CRM Tasks',
          icon: 'checklist',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetTaskService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_view crm_task_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_tasks',
          title: 'Search Tasks',
          description: 'Search CRM tasks by title, status, assignee, deal, or priority',
          group_name: 'CRM Tasks',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchTasksService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_view crm_task_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'list_task_custom_fields',
          title: 'List Task Custom Fields',
          description: 'List active allowed CRM custom fields for task custom_attributes with key, label, type, required flag, and select options',
          group_name: 'CRM Tasks',
          icon: 'custom-field',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ListTaskCustomFieldsTool,
          assistant_tool_class: Captain::Tools::Copilot::ListTaskCustomFieldsService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_view crm_task_manage],
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'get_task_timeline',
          title: 'Get Task Timeline',
          description: 'Get the timeline for a CRM task',
          group_name: 'CRM Tasks',
          icon: 'history',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetTaskTimelineService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_view crm_task_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'create_task',
          title: 'Create Task',
          description: 'Create a CRM task from the current conversation context',
          group_name: 'CRM Tasks',
          icon: 'checklist',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateTaskTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateTaskService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'list_channel_templates',
          title: 'List Channel Templates',
          description: 'List approved WhatsApp/Twilio channel templates for a conversation or inbox',
          group_name: 'Outbound',
          icon: 'template',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ListChannelTemplatesTool,
          assistant_tool_class: Captain::Tools::Copilot::ListChannelTemplatesService,
          required_permissions: %w[outbound_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'create_touch',
          title: 'Create Touch',
          description: 'Create a scheduled outbound touch with free text, attachments, or an approved official WhatsApp channel template. For official WhatsApp outside the 24-hour window, use channel_template instead of free_text or AI-generated text.',
          group_name: 'Outbound',
          icon: 'clock-plus',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateTouchTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateTouchService,
          required_permissions: %w[outbound_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'cancel_touch',
          title: 'Cancel Touch',
          description: 'Cancel a single draft or pending scheduled outbound touch by ID',
          group_name: 'Outbound',
          icon: 'clock-x',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CancelTouchTool,
          assistant_tool_class: Captain::Tools::Copilot::CancelTouchService,
          required_permissions: %w[outbound_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'delete_touch',
          title: 'Delete Touch',
          description: 'Delete a draft, pending, failed, or cancelled scheduled outbound touch by ID',
          group_name: 'Outbound',
          icon: 'trash',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::DeleteTouchTool,
          assistant_tool_class: Captain::Tools::Copilot::DeleteTouchService,
          required_permissions: %w[outbound_manage],
          risk_level: 'high'
        ),
        definition(
          id: 'cancel_touches',
          title: 'Cancel Touches',
          description: 'Cancel draft and pending scheduled outbound touches for the current entity, optionally filtered by touch plan',
          group_name: 'Outbound',
          icon: 'clock-x',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CancelTouchesTool,
          assistant_tool_class: Captain::Tools::Copilot::CancelTouchesService,
          required_permissions: %w[outbound_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'create_touch_plan',
          title: 'Create Touch Plan',
          description: 'Create a reusable outbound touch plan with one or more scheduled touch definitions',
          group_name: 'Outbound',
          icon: 'clock-plus',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateTouchPlanTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateTouchPlanService,
          required_permissions: %w[outbound_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'apply_touch_plan',
          title: 'Apply Touch Plan',
          description: 'Apply an existing outbound touch plan to the current conversation, deal, task, or appointment',
          group_name: 'Outbound',
          icon: 'clock-play',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ApplyTouchPlanTool,
          assistant_tool_class: Captain::Tools::Copilot::ApplyTouchPlanService,
          required_permissions: %w[outbound_manage],
          risk_level: 'high'
        ),
        definition(
          id: 'archive_touch_plan',
          title: 'Archive Touch Plan',
          description: 'Archive an outbound touch plan so it is no longer used for new scheduled touches',
          group_name: 'Outbound',
          icon: 'archive',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ArchiveTouchPlanTool,
          assistant_tool_class: Captain::Tools::Copilot::ArchiveTouchPlanService,
          required_permissions: %w[outbound_manage],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'request_confirmation',
          title: 'Request Confirmation',
          description: 'Create a universal confirmation request with channel-aware buttons, links, or text fallback',
          group_name: 'Confirmations',
          icon: 'check-circle',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::RequestConfirmationTool,
          assistant_tool_class: Captain::Tools::Copilot::RequestConfirmationService,
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'resolve_confirmation',
          title: 'Resolve Confirmation',
          description: 'Resolve a confirmation request as confirmed, declined, or reschedule requested with source audit metadata',
          group_name: 'Confirmations',
          icon: 'check',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ResolveConfirmationTool,
          assistant_tool_class: Captain::Tools::Copilot::ResolveConfirmationService,
          risk_level: 'high'
        ),
        definition(
          id: 'update_task',
          title: 'Update Task',
          description: 'Update the CRM task linked to the current conversation',
          group_name: 'CRM Tasks',
          icon: 'checklist-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateTaskTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateTaskService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'change_task_status',
          title: 'Change Task Status',
          description: 'Change the status of the CRM task linked to the current conversation',
          group_name: 'CRM Tasks',
          icon: 'shuffle',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ChangeTaskStatusTool,
          assistant_tool_class: Captain::Tools::Copilot::ChangeTaskStatusService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'high'
        ),
        definition(
          id: 'complete_task',
          title: 'Complete Task',
          description: 'Mark an account CRM task as complete by task ID',
          group_name: 'CRM Tasks',
          icon: 'check',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::CompleteTaskService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'add_task_comment',
          title: 'Add Task Comment',
          description: 'Add a comment to the CRM task linked to the current conversation',
          group_name: 'CRM Tasks',
          icon: 'comment',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::AddTaskCommentService,
          required_features: %w[crm_tasks],
          required_permissions: %w[crm_task_manage],
          risk_level: 'medium'
        ),
        definition(
          id: 'get_appointment',
          title: 'Get Appointment',
          description: 'Get details of an appointment',
          group_name: 'Scheduling',
          icon: 'calendar',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetAppointmentService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'search_appointments',
          title: 'Search Appointments',
          description: 'Search appointments by client, status, payment status, contact, or specialist',
          group_name: 'Scheduling',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchAppointmentsService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'list_appointment_custom_fields',
          title: 'List Appointment Custom Fields',
          description: 'List active allowed CRM custom fields for appointment custom_attributes with key, label, type, ' \
                       'required flag, and select options',
          group_name: 'Scheduling',
          icon: 'custom-field',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::ListAppointmentCustomFieldsTool,
          assistant_tool_class: Captain::Tools::Copilot::ListAppointmentCustomFieldsService,
          required_features: %w[scheduling],
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'list_scheduling_resources',
          title: 'List Specialists',
          description: 'List scheduling specialists, with optional filters for service and activity state',
          group_name: 'Scheduling',
          icon: 'users',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::ListSchedulingResourcesService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'search_scheduling_resources',
          title: 'Search Specialists',
          description: 'Search scheduling specialists by name or specialty, with optional service filtering',
          group_name: 'Scheduling',
          icon: 'user',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchSchedulingResourcesService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'get_scheduling_resource_schedule',
          title: 'Get Specialist Schedule',
          description: 'Get the normalized working schedule of a specialist for a date range, including overrides, breaks, holidays, and time off',
          group_name: 'Scheduling',
          icon: 'calendar-clock',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetSchedulingResourceScheduleService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'get_scheduling_resource_availability',
          title: 'Get Specialist Availability',
          description: 'Get free specialist appointment windows inside a time range, with service-aware duration when available',
          group_name: 'Scheduling',
          icon: 'calendar-search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetSchedulingResourceAvailabilityService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'search_scheduling_services',
          title: 'Search Services',
          description: 'Search scheduling services by name, category, or direction',
          group_name: 'Scheduling',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchSchedulingServicesService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'search_available_slots',
          title: 'Search Available Slots',
          description: 'Search appointment slots for one or more specialists using explicit specialist filters or a scheduling service',
          group_name: 'Scheduling',
          icon: 'calendar',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchAvailableSlotsService,
          required_features: %w[scheduling],
          risk_level: 'low'
        ),
        definition(
          id: 'create_appointment',
          title: 'Create Appointment',
          description: 'Create an appointment for the current conversation contact using a selected specialist and confirmed time details',
          group_name: 'Scheduling',
          icon: 'calendar-plus',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateAppointmentTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateAppointmentService,
          required_features: %w[scheduling],
          risk_level: 'high',
          idempotent: true
        ),
        definition(
          id: 'update_appointment',
          title: 'Update Appointment',
          description: 'Update the appointment linked to the current conversation with a new specialist, service, or confirmed time details',
          group_name: 'Scheduling',
          icon: 'calendar-edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::UpdateAppointmentTool,
          assistant_tool_class: Captain::Tools::Copilot::UpdateAppointmentService,
          required_features: %w[scheduling],
          risk_level: 'high'
        ),
        definition(
          id: 'cancel_appointment',
          title: 'Cancel Appointment',
          description: 'Cancel the appointment linked to the current conversation',
          group_name: 'Scheduling',
          icon: 'calendar-x',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CancelAppointmentTool,
          assistant_tool_class: Captain::Tools::Copilot::CancelAppointmentService,
          required_features: %w[scheduling],
          risk_level: 'high'
        ),
        definition(
          id: 'get_article',
          title: 'Get Article',
          description: 'Get details of an article including its content and metadata',
          group_name: 'Help center',
          icon: 'book-open',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetArticleService,
          required_permissions: %w[knowledge_base_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_articles',
          title: 'Search Articles',
          description: 'Search knowledge base articles by query, category, or status',
          group_name: 'Help center',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchArticlesService,
          required_permissions: %w[knowledge_base_manage],
          risk_level: 'low'
        ),
        definition(
          id: 'search_linear_issues',
          title: 'Search Linear Issues',
          description: 'Search Linear issues by a search term',
          group_name: 'Integrations',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchLinearIssuesService,
          risk_level: 'low'
        ),
        definition(
          id: 'send_message_to_conversation',
          title: 'Send Message to Conversation',
          description: 'Send a public reply, private note, attachments, or an approved channel template to a conversation',
          group_name: 'Conversations',
          icon: 'send',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SendMessageToConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'assign_conversation',
          title: 'Assign Conversation',
          description: 'Assign a conversation to an agent, agent bot, or team',
          group_name: 'Conversations',
          icon: 'user-switch',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::AssignConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'list_account_users',
          title: 'List Account Users',
          description: 'List account users with IDs, roles, availability, and team membership for assignment, notifications, and ownership fields',
          group_name: 'Account',
          icon: 'users',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::ListAccountUsersService,
          risk_level: 'low',
          selected_by_default: false
        ),
        definition(
          id: 'list_teams',
          title: 'List Teams',
          description: 'List account teams and optional members for assignment and routing decisions',
          group_name: 'Account',
          icon: 'people-team',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::ListTeamsService,
          risk_level: 'low',
          selected_by_default: false
        ),
        definition(
          id: 'retry_failed_message',
          title: 'Retry Failed Message',
          description: 'Retry a failed outgoing message in a conversation',
          group_name: 'Conversations',
          icon: 'refresh',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::RetryFailedMessageService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'edit_message',
          title: 'Edit Message',
          description: 'Edit a previously sent outgoing message when the channel supports it',
          group_name: 'Conversations',
          icon: 'edit',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::EditMessageService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'translate_message',
          title: 'Translate Message',
          description: 'Translate a conversation message into a target language',
          group_name: 'Conversations',
          icon: 'language',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::TranslateMessageService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'low'
        ),
        definition(
          id: 'search_canned_responses',
          title: 'Search Canned Responses',
          description: 'Search canned responses by short code or content',
          group_name: 'Support content',
          icon: 'search',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::SearchCannedResponsesService,
          risk_level: 'low'
        ),
        definition(
          id: 'create_canned_response',
          title: 'Create Canned Response',
          description: 'Create a reusable canned response',
          group_name: 'Support content',
          icon: 'note-add',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::CreateCannedResponseService,
          risk_level: 'medium'
        ),
        definition(
          id: 'merge_contacts',
          title: 'Merge Contacts',
          description: 'Merge one contact into another contact',
          group_name: 'Contacts',
          icon: 'users',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::MergeContactsService,
          required_permissions: %w[contact_manage],
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'add_appointment_payment',
          title: 'Add Appointment Payment',
          description: 'Add a payment to the appointment linked to the current conversation',
          group_name: 'Scheduling',
          icon: 'credit-card',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::AddAppointmentPaymentService,
          required_features: %w[scheduling scheduling_finance],
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'get_kaspi_pay_integration_status',
          title: 'Get Kaspi Pay Integration Status',
          description: 'Check whether Kaspi Pay is connected for this account without exposing tokens or secrets',
          group_name: 'Payments',
          icon: 'credit-card',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetKaspiPayIntegrationStatusService,
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'start_kaspi_pay_connection',
          title: 'Start Kaspi Pay Connection',
          description: 'Start the administrator-only Kaspi Pay merchant connection flow',
          group_name: 'Payments',
          icon: 'plug',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::StartKaspiPayConnectionService,
          risk_level: 'medium'
        ),
        definition(
          id: 'send_kaspi_pay_phone',
          title: 'Send Kaspi Pay Phone',
          description: 'Send a Kaspi Pay cashier/POS operator phone number during administrator-only connection flow',
          group_name: 'Payments',
          icon: 'phone',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SendKaspiPayPhoneService,
          risk_level: 'medium'
        ),
        definition(
          id: 'verify_kaspi_pay_otp',
          title: 'Verify Kaspi Pay OTP',
          description: 'Verify Kaspi Pay OTP and connect the merchant account without exposing session tokens',
          group_name: 'Payments',
          icon: 'shield-check',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::VerifyKaspiPayOtpService,
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'disconnect_kaspi_pay',
          title: 'Disconnect Kaspi Pay',
          description: 'Disconnect Kaspi Pay from this account',
          group_name: 'Payments',
          icon: 'plug-off',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::DisconnectKaspiPayService,
          required_integrations: %w[kaspi_pay],
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'create_kaspi_pay_payment',
          title: 'Create Kaspi Pay Payment',
          description: 'Create a Kaspi Pay QR payment link or assistant-only remote invoice. Customer-facing agent scope is limited to the current conversation QR flow; assistant scope is account-admin only.',
          group_name: 'Payments',
          icon: 'qr-code',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::CreateKaspiPayPaymentTool,
          assistant_tool_class: Captain::Tools::Copilot::CreateKaspiPayPaymentService,
          required_integrations: %w[kaspi_pay],
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'get_kaspi_pay_payment_status',
          title: 'Get Kaspi Pay Payment Status',
          description: 'Get or verify Kaspi Pay payment status for the current customer conversation only',
          group_name: 'Payments',
          icon: 'activity',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::GetKaspiPayPaymentStatusTool,
          assistant_tool_class: Captain::Tools::Copilot::GetKaspiPayPaymentStatusService,
          required_integrations: %w[kaspi_pay],
          risk_level: 'medium'
        ),
        definition(
          id: 'search_kaspi_pay_payments',
          title: 'Search Kaspi Pay Payments',
          description: 'Search Kaspi Pay payments within the current account',
          group_name: 'Payments',
          icon: 'search',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SearchKaspiPayPaymentsService,
          required_integrations: %w[kaspi_pay],
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'get_kaspi_pay_payment',
          title: 'Get Kaspi Pay Payment',
          description: 'Get one Kaspi Pay payment within the current account, optionally syncing latest provider status',
          group_name: 'Payments',
          icon: 'file-text',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetKaspiPayPaymentService,
          required_integrations: %w[kaspi_pay],
          risk_level: 'medium'
        ),
        definition(
          id: 'sync_kaspi_pay_payment_status',
          title: 'Sync Kaspi Pay Payment Status',
          description: 'Ask Kaspi Pay for the latest status of one account payment and update the local record',
          group_name: 'Payments',
          icon: 'refresh',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::SyncKaspiPayPaymentStatusService,
          required_integrations: %w[kaspi_pay],
          risk_level: 'medium'
        ),
        definition(
          id: 'refund_kaspi_pay_payment',
          title: 'Refund Kaspi Pay Payment',
          description: 'Admin-only: request a Kaspi Pay refund for one account payment',
          group_name: 'Payments',
          icon: 'arrow-counter-clockwise',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::RefundKaspiPayPaymentService,
          required_integrations: %w[kaspi_pay],
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'reconcile_kaspi_pay_payment',
          title: 'Reconcile Kaspi Pay Payment',
          description: 'Admin-only: fetch Kaspi operation details and reconcile local payment/refund status',
          group_name: 'Payments',
          icon: 'arrows-clockwise',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::ReconcileKaspiPayPaymentService,
          required_integrations: %w[kaspi_pay],
          risk_level: 'medium'
        ),
        definition(
          id: 'execute_macro',
          title: 'Execute Macro',
          description: 'Execute a macro for one or more conversations',
          group_name: 'Automation',
          icon: 'bolt',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::ExecuteMacroService,
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'get_account_health',
          title: 'Get Account Health',
          description: 'Get an account-scoped health snapshot for Captain, channels, and message delivery without exposing raw logs or secrets',
          group_name: 'Operations',
          icon: 'activity',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetAccountHealthService,
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'get_recent_account_errors',
          title: 'Get Recent Account Errors',
          description: 'List recent account-scoped AI/tool errors with sanitized payload details',
          group_name: 'Operations',
          icon: 'alert-triangle',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetRecentAccountErrorsService,
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'get_tool_execution_log',
          title: 'Get Tool Execution Log',
          description: 'List sanitized account-scoped Captain assistant tool execution events for RCA and debugging',
          group_name: 'Operations',
          icon: 'list-checks',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetToolExecutionLogService,
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'trace_ai_response',
          title: 'Trace AI Response',
          description: 'Trace an account-scoped Captain/LLM response by trace, request, session, or conversation identifier',
          group_name: 'Operations',
          icon: 'route',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::TraceAiResponseService,
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'trace_message_delivery',
          title: 'Trace Message Delivery',
          description: 'Trace outbound and incoming message delivery for one permissible account conversation',
          group_name: 'Operations',
          icon: 'send',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::TraceMessageDeliveryService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'get_channel_health',
          title: 'Get Channel Health',
          description: 'Get account-scoped inbox/channel health from messages and delivery failures without exposing provider secrets',
          group_name: 'Operations',
          icon: 'inbox',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetChannelHealthService,
          risk_level: 'low',
          idempotent: true
        ),
        definition(
          id: 'get_whatsapp_web_diagnostics',
          title: 'Get WhatsApp Web Diagnostics',
          description: 'Get runtime diagnostics for a WhatsApp Web inbox',
          group_name: 'Operations',
          icon: 'activity',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::GetWhatsappWebDiagnosticsService,
          risk_level: 'low'
        ),
        definition(
          id: 'reconnect_whatsapp_web',
          title: 'Reconnect WhatsApp Web',
          description: 'Reconnect a WhatsApp Web inbox',
          group_name: 'Operations',
          icon: 'refresh',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::ReconnectWhatsappWebService,
          risk_level: 'medium',
          requires_confirmation: true
        ),
        definition(
          id: 'create_label',
          title: 'Create Label',
          description: 'Create a new account label',
          group_name: 'Conversations',
          icon: 'tag',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::CreateLabelService,
          risk_level: 'medium'
        ),
        definition(
          id: 'update_label',
          title: 'Update Label',
          description: 'Update an existing account label',
          group_name: 'Conversations',
          icon: 'tag',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::UpdateLabelService,
          risk_level: 'medium'
        ),
        definition(
          id: 'remove_label_from_conversation',
          title: 'Remove Label from Conversation',
          description: 'Remove a label from the current conversation',
          group_name: 'Conversations',
          icon: 'tag',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::RemoveLabelFromConversationService,
          required_permissions: %w[
            conversation_manage
            conversation_unassigned_manage
            conversation_participating_manage
          ],
          risk_level: 'medium'
        ),
        definition(
          id: 'list_campaigns',
          title: 'List Campaigns',
          description: 'List campaigns for the current account',
          group_name: 'Outbound',
          icon: 'megaphone',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::ListCampaignsService,
          risk_level: 'low'
        ),
        definition(
          id: 'preview_campaign',
          title: 'Preview Campaign',
          description: 'Preview a campaign before sending it',
          group_name: 'Outbound',
          icon: 'eye',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::PreviewCampaignService,
          risk_level: 'low'
        ),
        definition(
          id: 'get_campaign_analytics',
          title: 'Get Campaign Analytics',
          description: 'Get analytics for a campaign',
          group_name: 'Outbound',
          icon: 'chart',
          allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
          agent_tool_class: Captain::Tools::Agent::AccountToolAdapter,
          assistant_tool_class: Captain::Tools::Copilot::GetCampaignAnalyticsService,
          risk_level: 'low'
        ),
        definition(
          id: 'retry_failed_campaign_deliveries',
          title: 'Retry Failed Campaign Deliveries',
          description: 'Retry failed deliveries for a campaign',
          group_name: 'Outbound',
          icon: 'refresh',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::RetryFailedCampaignDeliveriesService,
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'create_webhook',
          title: 'Create Webhook',
          description: 'Create an account webhook',
          group_name: 'Integrations',
          icon: 'link',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::CreateWebhookService,
          risk_level: 'high',
          requires_confirmation: true
        ),
        definition(
          id: 'update_webhook',
          title: 'Update Webhook',
          description: 'Update an existing account webhook',
          group_name: 'Integrations',
          icon: 'link',
          allowed_scopes: [Captain::ToolAccess::SCOPE_ASSISTANT],
          assistant_tool_class: Captain::Tools::Copilot::UpdateWebhookService,
          risk_level: 'high',
          requires_confirmation: true
        )
      ].freeze
    end

    def definition_for(tool_id)
      definitions.find { |definition| definition.id == tool_id.to_s }
    end

    def definition_for_class(tool_class, scope_name:)
      definitions.find { |definition| definition.tool_class_for(scope_name) == tool_class }
    end

    def tools_for_scope(scope_name)
      definitions.select { |definition| definition.supports_scope?(scope_name) }.map(&:to_h)
    end

    def resolve_agent_tool_class(tool_id)
      definition_for(tool_id)&.tool_class_for(Captain::ToolAccess::SCOPE_AGENT)
    end

    def resolve_assistant_tool_class(tool_id)
      definition_for(tool_id)&.tool_class_for(Captain::ToolAccess::SCOPE_ASSISTANT)
    end

    private

    def definition(**attributes)
      Definition.new(**attributes)
    end
  end
end
