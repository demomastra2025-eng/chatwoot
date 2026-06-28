import fromUnixTime from 'date-fns/fromUnixTime';
import format from 'date-fns/format';

const downloadFile = (fileName, content, contentType) => {
  const blob = new Blob([content], { type: contentType });
  const url = URL.createObjectURL(blob);

  const link = document.createElement('a');
  link.setAttribute('download', fileName);
  link.setAttribute('href', url);
  link.click();
  return link;
};

export const downloadCsvFile = (fileName, content) =>
  downloadFile(fileName, content, 'data:text/csv;charset=utf-8;');

export const downloadExcelFile = (fileName, content) =>
  downloadFile(fileName, content, 'application/vnd.ms-excel;charset=utf-8;');

export const generateFileName = ({
  type,
  to,
  businessHours = false,
  extension = 'csv',
}) => {
  let name = `${type}-report-${format(fromUnixTime(to), 'dd-MM-yyyy')}`;
  if (businessHours) {
    name = `${name}-business-hours`;
  }
  return `${name}.${extension}`;
};
