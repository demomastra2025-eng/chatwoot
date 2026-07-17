import { describe, it, expect, vi, beforeEach } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import { createStore } from 'vuex';

import PaymentActionButton from '../PaymentActionButton.vue';
import KaspiPayPaymentsAPI from 'dashboard/api/kaspiPayPayments';
import { useAlert } from 'dashboard/composables';
import QRCode from 'qrcode';

vi.mock('dashboard/api/kaspiPayPayments', () => ({
  default: {
    create: vi.fn(),
  },
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
}));

vi.mock('qrcode', () => ({
  default: {
    toDataURL: vi.fn(() => Promise.resolve('data:image/png;base64,cXI=')),
  },
}));

vi.mock('shared/helpers/clipboard', () => ({
  copyTextToClipboard: vi.fn(() => Promise.resolve()),
}));

const enabledKaspiPayIntegration = {
  id: 'kaspi_pay',
  hooks: [{ id: 38, status: 'enabled' }],
};

const createStoreWithIntegrations = (
  integrations = [enabledKaspiPayIntegration]
) =>
  createStore({
    modules: {
      integrations: {
        namespaced: true,
        getters: {
          getAppIntegrations: () => integrations,
        },
        actions: {
          get: vi.fn(),
        },
      },
    },
  });

const mountComponent = props =>
  mount(PaymentActionButton, {
    props: {
      conversationId: 5,
      ...props,
    },
    global: {
      plugins: [createStoreWithIntegrations()],
      mocks: {
        $t: (key, params = {}) =>
          ({
            'CONVERSATION.REPLYBOX.PAYMENTS.CREATE_QR_IMAGE':
              'Создать QR картинку',
            'CONVERSATION.REPLYBOX.PAYMENTS.KASPI_PAYMENT_TEXT': `Ссылка для оплаты Kaspi: ${params.link}\nСумма: ${params.amount} ${params.currency}`,
            'CONVERSATION.REPLYBOX.PAYMENTS.KASPI_QR_IMAGE_TEXT': `QR для оплаты Kaspi\nСсылка: ${params.link}\nСумма: ${params.amount} ${params.currency}`,
            'CONVERSATION.REPLYBOX.PAYMENTS.KASPI_INVOICE_TEXT': `Счёт Kaspi: ${params.orderNumber} ${params.amount} ${params.currency}`,
          })[key] || key,
      },
      directives: {
        tooltip: () => {},
        onClickaway: () => {},
      },
      stubs: {
        NextButton: {
          props: ['label', 'type', 'isLoading'],
          emits: ['click'],
          template:
            '<button :type="type || \'button\'" :disabled="isLoading" @click="$emit(\'click\')"><slot>{{ label }}</slot></button>',
        },
        DropdownMenu: {
          props: ['menuItems'],
          emits: ['action'],
          template:
            '<div class="payment-menu"><button v-for="item in menuItems" :key="item.value" type="button" :disabled="item.disabled" @click="$emit(\'action\', item)">{{ item.label }}</button></div>',
        },
      },
    },
  });

describe('PaymentActionButton', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('shows a visible amount form after selecting Kaspi QR from the reply box payment menu', async () => {
    const wrapper = mountComponent();

    await wrapper.find('button').trigger('click');
    await wrapper.find('.payment-menu button').trigger('click');

    const amountForm = wrapper.find('form');
    expect(amountForm.exists()).toBe(true);
    expect(amountForm.classes()).toContain('z-[160]');
    expect(KaspiPayPaymentsAPI.create).not.toHaveBeenCalled();
  });

  it('creates a conversation payment and emits replacement text after amount submit', async () => {
    KaspiPayPaymentsAPI.create.mockResolvedValue({
      data: {
        id: 12,
        amount: 15000,
        currency: 'KZT',
        qr_token: 'https://pay.example/qr/12',
      },
    });

    const wrapper = mountComponent();
    await wrapper.find('button').trigger('click');
    await wrapper.find('.payment-menu button').trigger('click');
    await wrapper.find('input').setValue('15000');
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(KaspiPayPaymentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        conversation_id: 5,
        amount: 15000,
        idempotency_key: expect.stringMatching(
          /^kaspi-pay:conversation:5:15000:qr:/
        ),
      })
    );
    expect(wrapper.emitted('replaceText')?.[0]?.[0]).toContain(
      'https://pay.example/qr/12'
    );
    expect(useAlert).toHaveBeenCalledWith(
      'CONVERSATION.REPLYBOX.PAYMENTS.CREATED'
    );
  });

  it('creates a QR image action from a separate menu item and attaches the generated image', async () => {
    KaspiPayPaymentsAPI.create.mockResolvedValue({
      data: {
        id: 13,
        amount: 15000,
        currency: 'KZT',
        payment_type: 'qr',
        qr_token: 'https://pay.example/qr/13',
        qr_original_token: 'https://qr.example/original/13',
      },
    });

    const wrapper = mountComponent();
    await wrapper.find('button').trigger('click');
    await wrapper.findAll('.payment-menu button')[1].trigger('click');
    expect(wrapper.find('form button[type="submit"]').text()).toBe(
      'Создать QR картинку'
    );
    await wrapper.find('input').setValue('15000');
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(KaspiPayPaymentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({ payment_type: 'qr', amount: 15000 })
    );
    expect(QRCode.toDataURL).toHaveBeenCalledWith(
      'https://qr.example/original/13',
      expect.objectContaining({ width: 256 })
    );
    const replacementText = wrapper.emitted('replaceText')?.[0]?.[0];
    expect(replacementText).toContain('https://qr.example/original/13');
    expect(replacementText).not.toContain('data:image/png;base64');

    const attachment = wrapper.emitted('attachFile')?.[0]?.[0];
    expect(attachment.name).toBe('kaspi-qr-13.png');
    expect(attachment.type).toBe('image/png');
    expect(attachment.file).toBeInstanceOf(File);
    expect(wrapper.emitted('created')?.[0]?.[0].attachment).toBe(attachment);
  });

  it('creates a Kaspi invoice action with phone number when selected', async () => {
    KaspiPayPaymentsAPI.create.mockResolvedValue({
      data: {
        id: 14,
        amount: 15000,
        currency: 'KZT',
        payment_type: 'invoice',
        kaspi_order_number: 'order-14',
      },
    });

    const wrapper = mountComponent();
    await wrapper.find('button').trigger('click');
    await wrapper.findAll('.payment-menu button')[2].trigger('click');
    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('15000');
    await inputs[1].setValue('77011234567');
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(KaspiPayPaymentsAPI.create).toHaveBeenCalledWith(
      expect.objectContaining({
        payment_type: 'invoice',
        phone_number: '77011234567',
        amount: 15000,
      })
    );
    expect(wrapper.emitted('replaceText')?.[0]?.[0]).toContain('order-14');
  });
});
