/** Who owns Table 1's own work (code, design, name, compiled data). Change to the company once it exists (legal/README.md). */
export const OWNER = "John Lindmark";
export const copyrightLine = (year = new Date().getFullYear()) => `© ${year} ${OWNER}. All rights reserved.`;
/** Shown wherever a link earns a commission (FTC: say so near the link). */
export const AFFILIATE_NOTE = "Table 1 may earn a commission on purchases made through TCGplayer links.";

/** The Wizards Fan Content Policy notice, required for using Magic names and card images (same words on iOS and Android). */
export const FAN_CONTENT =
  "Table 1 is unofficial Fan Content permitted under the Fan Content Policy. Not approved/endorsed by Wizards. Portions of the materials used are property of Wizards of the Coast. ©Wizards of the Coast LLC.";
