// ID cards and driving licences are landscape cards. One photographed with the
// phone upright arrives portrait, so it is shown turned a quarter to the left.
const LANDSCAPE_CARDS = new Set(["national_id_front", "national_id_back", "drivers_licence"]);

export function turnsLeft(documentType: string, width: number, height: number): boolean {
  return LANDSCAPE_CARDS.has(documentType) && height > width;
}
