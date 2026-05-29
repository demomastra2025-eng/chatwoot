import {
  extractChangedAccountUserValues,
  generateTranslationPayload,
  generateLogActionKey,
  getAuditLogChannelTypeLabel,
  getAuditLogChannelTypeSuffix,
} from '../auditlogHelper'; // import the functions

describe('Helper functions', () => {
  const agentList = [
    { id: 1, name: 'Agent 1' },
    { id: 2, name: 'Agent 2' },
    { id: 3, name: 'Agent 3' },
  ];
  const t = key => key;

  describe('extractChangedAccountUserValues', () => {
    it('should correctly extract values when role is changed', () => {
      const changes = {
        role: [0, 1],
      };
      const { changes: extractedChanges, values } =
        extractChangedAccountUserValues(changes);
      expect(extractedChanges).toEqual(['role']);
      expect(values).toEqual(['administrator']);
    });

    it('should correctly extract values when availability is changed', () => {
      const changes = {
        availability: [0, 2],
      };
      const { changes: extractedChanges, values } =
        extractChangedAccountUserValues(changes);
      expect(extractedChanges).toEqual(['availability']);
      expect(values).toEqual(['busy']);
    });

    it('should correctly extract values when both are changed', () => {
      const changes = {
        role: [1, 0],
        availability: [1, 2],
      };
      const { changes: extractedChanges, values } =
        extractChangedAccountUserValues(changes);
      expect(extractedChanges).toEqual(['role', 'availability']);
      expect(values).toEqual(['agent', 'busy']);
    });
  });

  describe('generateTranslationPayload', () => {
    it('should handle AccountUser create', () => {
      const auditLogItem = {
        auditable_type: 'AccountUser',
        action: 'create',
        user_id: 1,
        auditable_id: 123,
        audited_changes: {
          user_id: 2,
          role: 1,
        },
      };

      const payload = generateTranslationPayload(auditLogItem, agentList);
      expect(payload).toEqual({
        agentName: 'Agent 1',
        id: 123,
        invitee: 'Agent 2',
        role: 'administrator',
      });
    });

    it('should handle AccountUser update', () => {
      const auditLogItem = {
        auditable_type: 'AccountUser',
        action: 'update',
        user_id: 1,
        auditable_id: 123,
        audited_changes: {
          user_id: 2,
          role: [1, 0],
          availability: [0, 2],
        },
        auditable: {
          user_id: 3,
        },
      };

      const payload = generateTranslationPayload(auditLogItem, agentList);
      expect(payload).toEqual({
        agentName: 'Agent 1',
        id: 123,
        user: 'Agent 3',
        attributes: ['role', 'availability'],
        values: ['agent', 'busy'],
      });
    });

    it('should handle InboxMember or TeamMember', () => {
      const auditLogItemInboxMember = {
        auditable_type: 'InboxMember',
        action: 'create',
        audited_changes: {
          user_id: 2,
        },
        user_id: 1,
        auditable_id: 789,
      };

      const payloadInboxMember = generateTranslationPayload(
        auditLogItemInboxMember,
        agentList
      );
      expect(payloadInboxMember).toEqual({
        agentName: 'Agent 1',
        id: 789,
        user: 'Agent 2',
      });

      const auditLogItemTeamMember = {
        auditable_type: 'TeamMember',
        action: 'create',
        audited_changes: {
          user_id: 3,
        },
        user_id: 1,
        auditable_id: 789,
      };

      const payloadTeamMember = generateTranslationPayload(
        auditLogItemTeamMember,
        agentList
      );
      expect(payloadTeamMember).toEqual({
        agentName: 'Agent 1',
        id: 789,
        user: 'Agent 3',
      });
    });

    it('should handle generic case like Team create', () => {
      const auditLogItem = {
        auditable_type: 'Team',
        action: 'create',
        user_id: 1,
        auditable_id: 456,
      };

      const payload = generateTranslationPayload(auditLogItem, agentList);
      expect(payload).toEqual({
        agentName: 'Agent 1',
        id: 456,
      });
    });
  });

  describe('generateLogActionKey', () => {
    it('should generate correct action key when user updates self', () => {
      const auditLogItem = {
        auditable_type: 'AccountUser',
        action: 'update',
        user_id: 1,
        auditable: {
          user_id: 1,
        },
      };

      const logActionKey = generateLogActionKey(auditLogItem);
      expect(logActionKey).toEqual('AUDIT_LOGS.ACCOUNT_USER.EDIT.SELF');
    });

    it('should generate correct action key when user updates other agent', () => {
      const auditLogItem = {
        auditable_type: 'AccountUser',
        action: 'update',
        user_id: 1,
        auditable: {
          user_id: 2,
        },
      };

      const logActionKey = generateLogActionKey(auditLogItem);
      expect(logActionKey).toEqual('AUDIT_LOGS.ACCOUNT_USER.EDIT.OTHER');
    });

    it('should generate correct action key when updating a deleted user', () => {
      const auditLogItem = {
        auditable_type: 'AccountUser',
        action: 'update',
        user_id: 1,
        auditable: null,
      };

      const logActionKey = generateLogActionKey(auditLogItem);
      expect(logActionKey).toEqual('AUDIT_LOGS.ACCOUNT_USER.EDIT.DELETED');
    });
  });

  describe('getAuditLogChannelTypeLabel', () => {
    it('returns localized label for inbox audit items', () => {
      const auditLogItem = {
        auditable_type: 'Inbox',
        auditable: {
          channel_type: 'Channel::WhatsappWeb',
        },
      };

      expect(getAuditLogChannelTypeLabel(auditLogItem, t)).toEqual(
        'INBOX_MGMT.CHANNELS.WHATSAPP_WEB'
      );
    });

    it('uses whatsapp label for Twilio WhatsApp inboxes', () => {
      const auditLogItem = {
        auditable_type: 'Inbox',
        auditable: {
          channel_type: 'Channel::TwilioSms',
          medium: 'whatsapp',
        },
      };

      expect(getAuditLogChannelTypeLabel(auditLogItem, t)).toEqual(
        'INBOX_MGMT.CHANNELS.WHATSAPP'
      );
    });

    it('reads inbox type from inbox member payload', () => {
      const auditLogItem = {
        auditable_type: 'InboxMember',
        auditable: {
          inbox: {
            channel_type: 'Channel::Telegram',
          },
        },
      };

      expect(getAuditLogChannelTypeLabel(auditLogItem, t)).toEqual(
        'INBOX_MGMT.CHANNELS.TELEGRAM_BOT'
      );
    });

    it('falls back to configured API channel name', () => {
      const auditLogItem = {
        auditable_type: 'Inbox',
        auditable: {
          channel_type: 'Channel::Api',
        },
      };

      expect(
        getAuditLogChannelTypeLabel(auditLogItem, t, {
          apiChannelName: 'Custom API',
        })
      ).toEqual('Custom API');
    });

    it('falls back to audited changes for deleted twilio whatsapp inboxes', () => {
      const auditLogItem = {
        auditable_type: 'Inbox',
        auditable: null,
        audited_changes: {
          channel_type: 'Channel::TwilioSms',
          medium: 'whatsapp',
        },
      };

      expect(getAuditLogChannelTypeLabel(auditLogItem, t)).toEqual(
        'INBOX_MGMT.CHANNELS.WHATSAPP'
      );
    });
  });

  describe('getAuditLogChannelTypeSuffix', () => {
    it('returns a formatted suffix when channel type is available', () => {
      const auditLogItem = {
        auditable_type: 'Inbox',
        auditable: {
          channel_type: 'Channel::Email',
        },
      };

      expect(getAuditLogChannelTypeSuffix(auditLogItem, t)).toEqual(
        ' «INBOX_MGMT.CHANNELS.EMAIL»'
      );
    });

    it('returns an empty string when channel type is unavailable', () => {
      const auditLogItem = {
        auditable_type: 'Team',
        auditable: {},
      };

      expect(getAuditLogChannelTypeSuffix(auditLogItem, t)).toEqual('');
    });
  });
});
