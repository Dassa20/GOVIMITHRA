// ============================================================
// DEA CONTACTS — verified office details shown by the chatbot
// Source: official Department of Export Agriculture website
// (dea.gov.lk: Contact Us and District Offices pages).
// Only office addresses and office numbers are stored; officer
// names are left out because they change over time.
// Re-check these details before each release.
// ============================================================

class DeaOffice {
  final String nameEn;
  final String nameSi;
  final String addressEn;
  final List<String> phones; // dialable numbers
  final String? email;
  final String? district; // 'Galle', 'Matara', 'Kandy', 'Matale'; null for the head office
  const DeaOffice({
    required this.nameEn,
    required this.nameSi,
    required this.addressEn,
    required this.phones,
    this.email,
    this.district,
  });
}

const List<DeaOffice> deaOffices = [
  DeaOffice(
    nameEn: 'DEA Head Office (Peradeniya)',
    nameSi: 'අපනයන කෘෂිකර්ම දෙපාර්තමේන්තුව - ප්‍රධාන කාර්යාලය (පේරාදෙණිය)',
    addressEn:
        '#1095, Sirimavo Bandaranayake Mawatha, Getambe, Peradeniya',
    phones: ['+94812388651', '+94812386018', '+94812386019'],
    email: 'helpdesk@dea.gov.lk',
  ),
  DeaOffice(
    nameEn: 'DEA Galle District Office',
    nameSi: 'අපනයන කෘෂිකර්ම දෙපාර්තමේන්තුව - ගාල්ල කාර්යාලය',
    addressEn: 'Bandi Road, Labuduwa, Akmeemana, Galle',
    phones: ['+94912223494'],
    email: 'deagalle2018@gmail.com',
    district: 'Galle',
  ),
  DeaOffice(
    nameEn: 'DEA Matara District Office',
    nameSi: 'අපනයන කෘෂිකර්ම දෙපාර්තමේන්තුව - මාතර කාර්යාලය',
    addressEn: 'No 38, Rahula Road, Matara',
    phones: ['+94412222443'],
    email: 'deamatara2018@gmail.com',
    district: 'Matara',
  ),
  DeaOffice(
    nameEn: 'DEA Kandy District Office',
    nameSi: 'අපනයන කෘෂිකර්ම දෙපාර්තමේන්තුව - මහනුවර කාර්යාලය',
    addressEn: 'No 1062, Sirimavo Bandaranayake Mawatha, Peradeniya',
    phones: ['+94812388392'],
    email: 'deakandy2018@gmail.com',
    district: 'Kandy',
  ),
  DeaOffice(
    nameEn: 'DEA Matale District Office',
    nameSi: 'අපනයන කෘෂිකර්ම දෙපාර්තමේන්තුව - මාතලේ කාර්යාලය',
    addressEn: 'Elwala, Ukuwela, Matale',
    phones: ['+94662243451'],
    email: 'deamatale2018@gmail.com',
    district: 'Matale',
  ),
];

/// Turns +94812388651 into a readable local number: 081 238 8651
String prettyPhone(String e164) {
  final d = e164.replaceFirst('+94', '0');
  if (d.length == 10) {
    return '${d.substring(0, 3)} ${d.substring(3, 6)} ${d.substring(6)}';
  }
  return d;
}