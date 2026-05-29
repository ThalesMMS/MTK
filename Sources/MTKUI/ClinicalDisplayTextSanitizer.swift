import Foundation

public enum ClinicalDisplayTextSanitizer {
    public static func safeSeriesTitle(_ rawValue: String?) -> String? {
        guard let title = normalizedTitle(rawValue),
              !containsBlockedViewerText(title) else {
            return nil
        }

        return title
    }

    public static func safeStudyTitle(_ rawValue: String?) -> String? {
        safeSeriesTitle(rawValue)
    }

    public static func chromeTitle(_ rawValue: String?,
                                   fallback: String = "Clinical Viewer") -> String {
        safeSeriesTitle(rawValue) ?? fallback
    }

    public static func safeSubjectName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "^", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !matches(normalized, pattern: dicomPatientTagPattern),
              !matches(normalized, pattern: patientLabelPattern),
              !matches(normalized, pattern: brandingPattern),
              !(matches(normalized, pattern: agePattern) && matches(normalized, pattern: sexPattern)) else {
            return nil
        }
        return normalized
    }

    public static func containsBlockedViewerText(_ rawValue: String) -> Bool {
        let title = normalizedTitle(rawValue) ?? ""
        guard !title.isEmpty else { return false }

        if title.contains("^") {
            return true
        }

        if matches(title, pattern: dicomPatientTagPattern) ||
            matches(title, pattern: patientLabelPattern) ||
            matches(title, pattern: brandingPattern) {
            return true
        }

        return matches(title, pattern: agePattern) && matches(title, pattern: sexPattern)
    }
}

private extension ClinicalDisplayTextSanitizer {
    static let dicomPatientTagPattern = #"\b0010\s*,\s*(0010|0020|0040|1010)\b"#
    static let patientLabelPattern = #"\b(patient\s*name|patientname|patient\s*id|patientid|patient\s*age|patientage|patient\s*sex|patientsex|mrn|medical\s*record|accession|study\s*id|birth\s*date|birthdate|dob|institution|referring\s*physician|operator\s*name)\b"#
    static let brandingPattern = #"\b(watermark|vendor|powered\s+by|copyright|external\s+viewer|viewer\s+logo|branding|branded)\b"#
    static let agePattern = #"\b(\d{3}[YMWD]|\d{1,3}\s*(years?|yrs?|yo))\b"#
    static let sexPattern = [
        #"\b(male|female|other)\b"#,
        #"\b(sex|gender)\s*[:=]?\s*[MFO]\b(?!\s*/)"#,
        #"\b(\d{3}[YMWD]|\d{1,3}\s*(years?|yrs?|yo))\s*[-,]?\s*[MFO]\b(?!\s*/)"#,
        #"\b[MFO]\b(?!\s*/)\s*[-,]?\s*(\d{3}[YMWD]|\d{1,3}\s*(years?|yrs?|yo))\b"#
    ].joined(separator: "|")

    static func normalizedTitle(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let title = rawValue
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return title.isEmpty ? nil : title
    }

    static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }
}
