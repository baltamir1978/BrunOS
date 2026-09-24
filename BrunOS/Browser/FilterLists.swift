import Foundation

/// Una lista de filtros que el bloqueador sabe bajar: las de uBlock Origin y
/// las que Bruno añada por su dirección.
///
/// **El catálogo es el de uBlock Origin** (`assets/assets.json` de su
/// repositorio, 24-sep-2026), con las mismas direcciones y los mismos grupos.
/// Se deja fuera «URL Tracking Protection»: sólo lleva `$removeparam`, que
/// WebKit no sabe hacer, y se quedaría en cero reglas.
struct FilterList: Identifiable, Hashable, Sendable {

    enum Group: String, CaseIterable, Sendable {
        case builtIn, ads, privacy, malware, annoyances, multipurpose, regions, custom

        var title: String {
            switch self {
            case .builtIn: "uBlock Origin"
            case .ads: "Anuncios"
            case .privacy: "Privacidad"
            case .malware: "Malware y estafas"
            case .annoyances: "Molestias"
            case .multipurpose: "Varios usos"
            case .regions: "Regionales"
            case .custom: "Propias"
            }
        }
    }

    let id: String
    let title: String
    let group: Group
    let url: URL
    /// Encendida mientras no se toque nada: las mismas que trae uBlock Origin
    /// de serie, más la española.
    var isDefault = false
}

extension FilterList {

    private static func list(
        _ id: String, _ title: String, _ group: Group, _ url: String, on: Bool = false
    ) -> FilterList {
        // Las direcciones son literales de este fichero: si una no fuera
        // válida, se vería al abrir los ajustes.
        FilterList(id: id, title: title, group: group, url: URL(string: url)!, isDefault: on)
    }

    private static let ubo = "https://ublockorigin.github.io/uAssets"
    private static let adguard = "https://filters.adtidy.org/extension/ublock/filters"
    private static let github = "https://raw.githubusercontent.com"

    static let catalog: [FilterList] = [
        list("ublock-filters", "Anuncios", .builtIn, "\(ubo)/filters/filters.txt", on: true),
        list("ublock-badware", "Riesgos de malware", .builtIn, "\(ubo)/filters/badware.txt", on: true),
        list("ublock-privacy", "Privacidad", .builtIn, "\(ubo)/filters/privacy.txt", on: true),
        list("ublock-unbreak", "Arreglos (Unbreak)", .builtIn, "\(ubo)/filters/unbreak.txt", on: true),
        list("ublock-quick-fixes", "Arreglos rápidos", .builtIn, "\(ubo)/filters/quick-fixes.txt", on: true),
        list("ublock-experimental", "Experimental", .builtIn, "\(ubo)/filters/experimental.txt"),

        list("easylist", "EasyList", .ads, "\(ubo)/thirdparties/easylist.txt", on: true),
        list("adguard-generic", "AdGuard · Anuncios", .ads, "\(adguard)/2_without_easylist.txt"),
        list("adguard-mobile", "AdGuard · Anuncios móviles", .ads, "\(adguard)/11.txt"),

        list("easyprivacy", "EasyPrivacy", .privacy, "\(ubo)/thirdparties/easyprivacy.txt", on: true),
        list("block-lan", "Bloquear intrusiones en la red local", .privacy, "\(ubo)/filters/lan-block.txt"),

        list("urlhaus-1", "Online Malicious URL Blocklist", .malware,
             "https://malware-filter.gitlab.io/urlhaus-filter/urlhaus-filter-ag-online.txt", on: true),
        list("curben-phishing", "Phishing URL Blocklist", .malware,
             "https://malware-filter.gitlab.io/phishing-filter/phishing-filter.txt"),

        list("ublock-cookies", "uBlock · Avisos de cookies", .annoyances, "\(ubo)/filters/annoyances-cookies.txt"),
        list("fanboy-cookiemonster", "EasyList · Avisos de cookies", .annoyances,
             "\(ubo)/thirdparties/easylist-cookies.txt"),
        list("adguard-cookies", "AdGuard · Avisos de cookies", .annoyances, "\(adguard)/18.txt"),
        list("ublock-annoyances", "uBlock · Molestias", .annoyances, "\(ubo)/filters/annoyances.txt"),
        list("easylist-annoyances", "EasyList · Otras molestias", .annoyances,
             "\(ubo)/thirdparties/easylist-annoyances.txt"),
        list("easylist-newsletters", "EasyList · Suscripciones", .annoyances,
             "\(ubo)/thirdparties/easylist-newsletters.txt"),
        list("easylist-notifications", "EasyList · Notificaciones", .annoyances,
             "\(ubo)/thirdparties/easylist-notifications.txt"),
        list("easylist-chat", "EasyList · Chats", .annoyances, "\(ubo)/thirdparties/easylist-chat.txt"),
        list("fanboy-ai-suggestions", "EasyList · Widgets de IA", .annoyances, "\(ubo)/thirdparties/easylist-ai.txt"),
        list("fanboy-social", "EasyList · Botones sociales", .annoyances, "\(ubo)/thirdparties/easylist-social.txt"),
        list("fanboy-thirdparty_social", "Fanboy · Anti-Facebook", .annoyances,
             "https://secure.fanboy.co.nz/fanboy-antifacebook.txt"),
        list("adguard-social", "AdGuard · Botones sociales", .annoyances, "\(adguard)/4.txt"),
        list("adguard-popup-overlays", "AdGuard · Ventanas emergentes", .annoyances, "\(adguard)/19.txt"),
        list("adguard-mobile-app-banners", "AdGuard · Banners de apps", .annoyances, "\(adguard)/20.txt"),
        list("adguard-other-annoyances", "AdGuard · Otras molestias", .annoyances, "\(adguard)/21.txt"),
        list("adguard-widgets", "AdGuard · Widgets", .annoyances, "\(adguard)/22.txt"),

        list("plowe-0", "Peter Lowe’s Ad and tracking server list", .multipurpose,
             "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext",
             on: true),
        list("dpollock-0", "Dan Pollock’s hosts file", .multipurpose, "https://someonewhocares.org/hosts/hosts"),

        list("spa-0", "España y Latinoamérica · EasyList Spanish", .regions,
             "https://easylist-downloads.adblockplus.org/easylistspanish.txt", on: true),
        list("spa-1", "España y Portugal · AdGuard Spanish/Portuguese", .regions, "\(adguard)/9.txt"),
        list("ALB-0", "Albania · Adblock List for Albania", .regions,
             "\(github)/AnXh3L0/blocklist/master/albanian-easylist-addition/Albania.txt"),
        list("ara-0", "Árabe · Liste AR", .regions, "https://easylist-downloads.adblockplus.org/Liste_AR.txt"),
        list("BGR-0", "Bulgaria · Bulgarian Adblock list", .regions, "https://stanev.org/abp/adblock_bg.txt"),
        list("CHN-0", "China · AdGuard Chinese", .regions, "\(adguard)/224.txt"),
        list("CZE-0", "Chequia y Eslovaquia · EasyList Czech and Slovak", .regions,
             "\(github)/tomasko126/easylistczechandslovak/master/filters.txt"),
        list("DEU-0", "Alemania · EasyList Germany", .regions, "https://easylist.to/easylistgermany/easylistgermany.txt"),
        list("EST-0", "Estonia · Eesti saitidele kohandatud filter", .regions, "https://ubo-et.lepik.io/list.txt"),
        list("FIN-0", "Finlandia · Adblock List for Finland", .regions,
             "\(github)/finnish-easylist-addition/finnish-easylist-addition/gh-pages/Finland_adb.txt"),
        list("FRA-0", "Francia · AdGuard Français", .regions, "\(adguard)/16.txt"),
        list("GRC-0", "Grecia · Greek AdBlock Filter", .regions, "https://www.void.gr/kargig/void-gr-filters.txt"),
        list("HRV-0", "Croacia y Serbia · Dandelion Sprout", .regions,
             "\(github)/DandelionSprout/adfilt/master/SerboCroatianList.txt"),
        list("HUN-0", "Hungría · hufilter", .regions,
             "https://cdn.jsdelivr.net/gh/hufilter/hufilter@gh-pages/hufilter-ublock.txt"),
        list("IDN-0", "Indonesia y Malasia · ABPindo", .regions,
             "\(github)/ABPindo/indonesianadblockrules/master/subscriptions/abpindo.txt"),
        list("IND-0", "India · IndianList", .regions, "https://easylist-downloads.adblockplus.org/indianlist.txt"),
        list("IRN-0", "Irán · PersianBlocker", .regions, "\(github)/MasterKia/PersianBlocker/main/PersianBlocker.txt"),
        list("ISL-0", "Islandia · Icelandic ABP List", .regions, "\(github)/brave/adblock-lists/master/custom/is.txt"),
        list("ISR-0", "Israel · EasyList Hebrew", .regions,
             "\(github)/easylist/EasyListHebrew/master/EasyListHebrew.txt"),
        list("ITA-0", "Italia · EasyList Italy", .regions, "https://easylist-downloads.adblockplus.org/easylistitaly.txt"),
        list("JPN-1", "Japón · AdGuard Japanese", .regions, "\(adguard)/7.txt"),
        list("KOR-1", "Corea · Korean filters", .regions,
             "https://cdn.jsdelivr.net/npm/@filteringdev/filterslists-ko@latest/dist/filterslist-uBlockOrigin-classic.txt"),
        list("LTU-0", "Lituania · EasyList Lithuania", .regions,
             "\(github)/EasyList-Lithuania/easylist_lithuania/master/easylistlithuania.txt"),
        list("LVA-0", "Letonia · Latvian List", .regions,
             "\(github)/Latvian-List/adblock-latvian/master/lists/latvian-list.txt"),
        list("MKD-0", "Macedonia · Macedonian adBlock Filters", .regions,
             "\(github)/DeepSpaceHarbor/Macedonian-adBlock-Filters/master/Filters"),
        list("NLD-0", "Países Bajos · AdGuard Dutch", .regions, "\(adguard)/8.txt"),
        list("NOR-0", "Nórdicos · Dandelion Sprouts nordiske filtre", .regions,
             "\(github)/DandelionSprout/adfilt/master/NorwegianList.txt"),
        list("POL-0", "Polonia · Polskie Filtry", .regions,
             "\(github)/MajkiIT/polish-ads-filter/master/polish-adblock-filters/adblock.txt"),
        list("POL-3", "Polonia · CERT.PL Warning List", .regions, "https://hole.cert.pl/domains/v2/domains_ublock.txt"),
        list("ROU-1", "Rumanía · ROad Block Light", .regions,
             "\(github)/tcptomato/ROad-Block/master/road-block-filters-light.txt"),
        list("RUS-0", "Rusia · RU AdList", .regions, "\(github)/easylist/ruadlist/master/RuAdList-uBO.txt"),
        list("RUS-1", "Rusia · RU AdList: Counters", .regions, "\(github)/easylist/ruadlist/master/cntblock.txt"),
        list("SVN-0", "Eslovenia · Slovenian List", .regions,
             "\(github)/betterwebleon/slovenian-list/master/filters.txt"),
        list("SWE-1", "Suecia · Frellwit’s Swedish Filter", .regions,
             "\(github)/lassekongo83/Frellwits-filter-lists/master/Frellwits-Swedish-Filter.txt"),
        list("THA-0", "Tailandia · EasyList Thailand", .regions,
             "\(github)/easylist-thailand/easylist-thailand/master/subscription/easylist-thailand.txt"),
        list("TUR-0", "Turquía · AdGuard Turkish", .regions, "\(adguard)/13.txt"),
        list("UKR-0", "Ucrania · AdGuard Ukrainian", .regions, "\(adguard)/23.txt"),
        list("VIE-1", "Vietnam · ABPVN List", .regions, "\(github)/abpvn/abpvn/master/filter/abpvn_ublock.txt"),
    ]
}
