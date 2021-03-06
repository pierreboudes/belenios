let get_lang = function
  | "fr" -> (module Web_l10n_fr : Web_i18n_sig.LocalizedStrings)
  | "de" -> (module Web_l10n_de : Web_i18n_sig.LocalizedStrings)
  | "ro" -> (module Web_l10n_ro : Web_i18n_sig.LocalizedStrings)
  | "it" -> (module Web_l10n_it : Web_i18n_sig.LocalizedStrings)
  | _ -> (module Web_l10n_en : Web_i18n_sig.LocalizedStrings)
