import { generateFileName } from '../downloadHelper';

describe('#generateFileName', () => {
  it('should generate the correct file name', () => {
    expect(generateFileName({ type: 'csat', to: 1652812199 })).toEqual(
      'csat-report-17-05-2022.csv'
    );

    expect(
      generateFileName({ type: 'csat', to: 1652812199, businessHours: true })
    ).toEqual('csat-report-17-05-2022-business-hours.csv');

    expect(
      generateFileName({
        type: 'manager-effectiveness',
        to: 1652812199,
        extension: 'xls',
      })
    ).toEqual('manager-effectiveness-report-17-05-2022.xls');
  });
});
