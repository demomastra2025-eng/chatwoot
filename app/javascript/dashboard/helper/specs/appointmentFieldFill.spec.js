import { describe, expect, it, vi } from 'vitest';
import axios from 'axios';
import {
  appointmentFieldIds,
  blockingFieldStats,
  fetchAppointmentFieldFill,
} from '../appointmentFieldFill';

vi.mock('axios', () => ({ default: { get: vi.fn() } }));

describe('appointmentFieldFill', () => {
  it('finds every appointment field reference once', () => {
    expect(
      appointmentFieldIds([
        '[Name](field://appointment.client_name) [Service](field://appointment.service_name_snapshot)',
        '[Name](field://appointment.client_name)',
      ])
    ).toEqual(['appointment.client_name', 'appointment.service_name_snapshot']);
  });

  it('keeps only blocking mapped fields', () => {
    const stats = [
      { field_id: 'appointment.client_name', blocking: false },
      { field_id: 'appointment.service_name_snapshot', blocking: true },
    ];
    expect(
      blockingFieldStats(stats, ['appointment.service_name_snapshot'])
    ).toEqual([stats[1]]);
  });

  it('requests the account-scoped stats endpoint', async () => {
    axios.get.mockResolvedValue({
      data: [{ field_id: 'appointment.client_name' }],
    });
    await expect(
      fetchAppointmentFieldFill(3, ['appointment.client_name'])
    ).resolves.toHaveLength(1);
    expect(axios.get).toHaveBeenCalledWith(
      '/api/v1/accounts/3/scheduling/appointment_field_fill',
      {
        params: { field_ids: ['appointment.client_name'] },
      }
    );
  });
});
