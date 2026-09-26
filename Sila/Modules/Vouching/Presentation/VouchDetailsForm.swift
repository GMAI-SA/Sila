import SwiftUI

/// The three details both sides of a vouch give (contract v24 §11) while
/// they are being typed: a full name, a nationality from the list, and a
/// date of birth that counts only once it has been chosen.
///
/// Never pre-filled from anything the other side wrote — there is nothing
/// on the device to pre-fill it with, and that is the point.
public struct VouchDetailsDraft: Equatable, Sendable {
    public var fullName = ""
    public var nationality: String?
    /// Midnight UTC of the chosen day, or `nil` until the wheel has been
    /// opened — a default date nobody picked must never be sent as theirs.
    public var dateOfBirth: Date?

    public init(fullName: String = "", nationality: String? = nil, dateOfBirth: Date? = nil) {
        self.fullName = fullName
        self.nationality = nationality
        self.dateOfBirth = dateOfBirth
    }

    /// The day as the wire carries it.
    public var dateOfBirthDay: String? { dateOfBirth.map(ISODay.string) }

    /// Everything filled in: what goes on the wire, the name exactly as
    /// typed apart from the ends — the server folds the rest.
    public var details: VouchDetails? {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let nationality, let day = dateOfBirthDay else { return nil }
        return VouchDetails(fullName: name, nationality: nationality, dateOfBirth: day)
    }

    /// Age on `today` in whole years, read in UTC like the day itself.
    public func age(on today: Date = Date()) -> Int? {
        guard let dateOfBirth else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateComponents([.year], from: dateOfBirth, to: today).year
    }

    /// The contract's floor: nobody under 18 is vouched for. The server
    /// checks again, against its own minimum if that is ever higher.
    public static let minimumAge = 18

    public func isUnderAge(on today: Date = Date()) -> Bool {
        guard let age = age(on: today) else { return false }
        return age < Self.minimumAge
    }
}

/// The form for ``VouchDetailsDraft``, shared by the link (the voucher
/// writing about somebody) and the claim (the person writing about
/// themselves).
@MainActor
struct VouchDetailsForm: View {

    @Binding var draft: VouchDetailsDraft
    /// "Their" on the link, "your" on the claim.
    let isOwn: Bool
    /// Fields a claim did not match — highlighted, never filled in.
    var mismatched: Set<VouchDetailField> = []
    /// A field the server refused, with its sentence.
    var errors: [VouchDetailField: String] = [:]

    @State private var isPickingNationality = false
    @State private var isChoosingDate = false
    @State private var wheel = Calendar(identifier: .gregorian).date(byAdding: .year, value: -25, to: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            SLTextField(
                L10n.t("vouch.form.fullName"),
                text: $draft.fullName,
                placeholder: isOwn ? L10n.t("vouch.form.fullName.placeholder.own") : L10n.t("vouch.form.fullName.placeholder"),
                contentType: isOwn ? .name : nil,
                autocapitalization: .words,
                error: message(for: .fullName)
            )
            .accessibilityIdentifier("vouching.form.fullName")

            fieldRow(
                field: .nationality,
                title: L10n.t("vouch.form.nationality"),
                value: draft.nationality.flatMap { CountryCode.name($0) },
                placeholder: L10n.t("vouch.form.choose"),
                identifier: "vouching.form.nationality"
            ) { isPickingNationality = true }

            fieldRow(
                field: .dateOfBirth,
                title: L10n.t("vouch.form.dateOfBirth"),
                value: draft.dateOfBirth.map(Self.dayText),
                placeholder: L10n.t("vouch.form.choose"),
                identifier: "vouching.form.dateOfBirth"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { isChoosingDate.toggle() }
                // Opening the wheel is the choice: whatever it shows is
                // what they are looking at, and they can turn it from there.
                if draft.dateOfBirth == nil { draft.dateOfBirth = wheel }
            }

            if isChoosingDate {
                DatePicker(
                    L10n.t("vouch.form.dateOfBirth"),
                    selection: Binding(
                        get: { draft.dateOfBirth ?? wheel },
                        set: { draft.dateOfBirth = $0; wheel = $0 }
                    ),
                    in: Self.range,
                    displayedComponents: .date
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                // Read and written in UTC, like ``ISODay``: a birthdate is a
                // day, and midnight in Riyadh is the day before in UTC.
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .environment(\.calendar, Self.calendar)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("vouching.form.dateWheel")
            }
        }
        .sheet(isPresented: $isPickingNationality) {
            NationalityPickerSheet(
                selected: draft.nationality,
                message: isOwn ? L10n.t("vouch.form.nationality.message.own") : L10n.t("vouch.form.nationality.message")
            ) { code in
                draft.nationality = code
                isPickingNationality = false
            }
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The chosen day, written in UTC so it is the day on the wheel.
    static func dayText(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L10n.formattingLocale,
                             calendar: calendar, timeZone: TimeZone(identifier: "UTC")!)
        )
    }

    /// A hundred and twenty years back to today — the server's own bounds.
    private static var range: ClosedRange<Date> {
        let now = Date()
        return (calendar.date(byAdding: .year, value: -120, to: now) ?? now)...now
    }

    private func message(for field: VouchDetailField) -> String? {
        if let error = errors[field] { return error }
        return mismatched.contains(field) ? L10n.t("vouch.form.mismatch") : nil
    }

    /// A tappable row for a value chosen elsewhere.
    private func fieldRow(
        field: VouchDetailField,
        title: String,
        value: String?,
        placeholder: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let problem = message(for: field)
        return VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text(title)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
            Button(action: action) {
                HStack {
                    Text(value ?? placeholder)
                        .font(SLFont.body)
                        .foregroundStyle(value == nil ? SLColor.textMuted : SLColor.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SLColor.textMuted)
                }
                .padding(.horizontal, SLSpacing.md)
                .frame(minHeight: 48)
                .background(SLColor.surface1)
                .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: SLRadius.md)
                        .strokeBorder(problem == nil ? SLColor.stroke : SLColor.danger, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(title): \(value ?? placeholder)"))
            .accessibilityIdentifier(identifier)
            if let problem {
                Text(problem)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One promise, as a box to tick.
@MainActor
struct AttestationRow: View {
    let text: String
    @Binding var isOn: Bool
    var identifier: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: SLSpacing.md) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? SLColor.primary : SLColor.textMuted)
                Text(text)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}
