// ============================================================
// CROP / DISTRICT DISPLAY LABELS
// The Flask backend returns crop/district names in English
// (e.g. "Cinnamon", "Galle") — these are also the exact values
// used in API calls, so they must NOT change internally.
// This file only maps them to Sinhala for DISPLAY. The actual
// value passed to dropdowns, chips, and API calls stays English.
// ============================================================

const Map<String, String> _cropSi = {
  'Cinnamon': 'කුරුඳු',
  'Pepper'  : 'ගම්මිරිස්',
};

const Map<String, String> _districtSi = {
  'Galle'  : 'ගාල්ල',
  'Matara' : 'මාතර',
  'Kandy'  : 'මහනුවර',
  'Matale' : 'මාතලේ',
};

/// Returns the Sinhala label for a crop if [si] is true and a
/// translation exists; otherwise returns the original English value.
String localizedCrop(String crop, bool si) {
  if (!si) return crop;
  return _cropSi[crop] ?? crop;
}

/// Returns the Sinhala label for a district if [si] is true and a
/// translation exists; otherwise returns the original English value.
String localizedDistrict(String district, bool si) {
  if (!si) return district;
  return _districtSi[district] ?? district;
}
