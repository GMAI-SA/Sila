import SwiftUI

/// The viewer's groups: make one, put people in it, take them out.
///
/// A group is private. The sheet says so once, at the top, because the
/// natural assumption — that adding somebody tells them — is wrong here.
@MainActor
public struct GroupsSheet: View {

    @State private var viewModel: GroupsViewModel
    /// Which list the picker feeds: the new group, or one being edited.
    @State private var picking: PickTarget?

    private enum PickTarget: Identifiable {
        case newGroup
        case group(UUID)
        var id: String {
            switch self {
            case .newGroup: return "new"
            case let .group(id): return id.uuidString
            }
        }
    }
    private let onClose: @MainActor () -> Void
    /// Called with a group the user tapped to pick, when picking is the point.
    private let onPick: (@MainActor (UserGroup) -> Void)?

    public init(
        viewModel: GroupsViewModel,
        onClose: @escaping @MainActor () -> Void,
        onPick: (@MainActor (UserGroup) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onClose = onClose
        self.onPick = onPick
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    Text(L10n.t("groups.explanation"))
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    newGroup

                    if viewModel.isLoading && !viewModel.hasLoaded {
                        SLSkeletonRow(lineCount: 3)
                    } else if viewModel.groups.isEmpty {
                        SLEmptyState(
                            icon: "person.3",
                            title: L10n.t("groups.empty.title"),
                            subtitle: L10n.t("groups.empty.message")
                        )
                    } else {
                        ForEach(viewModel.groups) { group in
                            groupCard(group)
                        }
                    }
                }
                .padding(SLSpacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("groups.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("common.done"), action: onClose)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            .task { await viewModel.load() }
            .confirmationDialog(
                Text(L10n.t("groups.delete.confirm.title", viewModel.pendingDeletion?.name ?? "")),
                isPresented: Binding(
                    get: { viewModel.pendingDeletion != nil },
                    set: { if !$0 { viewModel.cancelDeletion() } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.t("groups.delete.confirm.button"), role: .destructive) {
                    Task { await viewModel.confirmDeletion() }
                }
                Button(L10n.t("common.cancel"), role: .cancel) { viewModel.cancelDeletion() }
            } message: {
                Text(L10n.t("groups.delete.confirm.message"))
            }
            .sheet(item: $picking) { target in
                if let directory = viewModel.people {
                    PeoplePickerSheet(
                        viewModel: PeoplePickerViewModel(
                            directory: directory,
                            viewerHandle: viewModel.viewerHandle,
                            excluding: excluded(for: target)
                        ),
                        onPick: { people in
                            switch target {
                            case .newGroup: viewModel.pickForNew(people)
                            case .group: Task { await viewModel.addMembers(people: people) }
                            }
                        },
                        onClose: { picking = nil }
                    )
                }
            }
            .tnToast($viewModel.toast)
        }
    }

    private func excluded(for target: PickTarget) -> [String] {
        switch target {
        case .newGroup: return viewModel.handles
        case let .group(id): return viewModel.groups.first { $0.id == id }?.members.map(\.handle) ?? []
        }
    }

    // MARK: - New group

    private var newGroup: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            SLTextField(
                L10n.t("groups.new.name.label"),
                text: $viewModel.nameText,
                placeholder: L10n.t("groups.new.name.placeholder"),
                accessibilityHint: L10n.t("groups.new.name.a11yHint")
            )
            if viewModel.editingId == nil {
                if viewModel.people != nil {
                    SLButton(
                        L10n.t("people.picker.choose"),
                        variant: .secondary,
                        size: .compact,
                        icon: "person.2.badge.plus",
                        action: { picking = .newGroup }
                    )
                }
                if !viewModel.pickedForNew.isEmpty {
                    pickedPeople(viewModel.pickedForNew, remove: { viewModel.removePickedForNew($0) })
                }
                SLTextField(
                    L10n.t("groups.new.handles.label"),
                    text: $viewModel.handlesText,
                    placeholder: L10n.t("groups.new.handles.placeholder"),
                    accessibilityHint: L10n.t("groups.new.handles.a11yHint")
                )
            }
            SLButton(
                L10n.t("groups.new.create"),
                variant: .primary,
                size: .compact,
                icon: "plus",
                isLoading: viewModel.isSaving && viewModel.editingId == nil,
                isEnabled: viewModel.canCreate,
                asyncAction: { await viewModel.create() }
            )
        }
    }

    // MARK: - One group

    private func groupCard(_ group: UserGroup) -> some View {
        let isEditing = viewModel.editingId == group.id
        return SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HStack(spacing: SLSpacing.sm) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SLColor.primary)
                    Text(group.name)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: group.name))
                    Spacer(minLength: 0)
                    Text(L10n.plural("groups.members.count", group.memberCount))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                    if let onPick {
                        SLButton(
                            L10n.t("groups.pick"),
                            variant: .primary,
                            size: .compact,
                            action: { onPick(group) }
                        )
                    } else {
                        Button {
                            viewModel.editingId = isEditing ? nil : group.id
                            viewModel.handlesText = ""
                        } label: {
                            Image(systemName: isEditing ? "chevron.up" : "pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SLColor.primary)
                                .frame(width: 32, height: 28)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text(L10n.t("groups.edit.a11yLabel", group.name)))
                    }
                }

                if !group.members.isEmpty {
                    membersRow(group, editable: isEditing)
                }

                if isEditing {
                    if viewModel.people != nil {
                        SLButton(
                            L10n.t("people.picker.choose"),
                            variant: .secondary,
                            size: .compact,
                            icon: "person.2.badge.plus",
                            isLoading: viewModel.isSaving,
                            action: { picking = .group(group.id) }
                        )
                    }
                    SLTextField(
                        L10n.t("groups.new.handles.label"),
                        text: $viewModel.handlesText,
                        placeholder: L10n.t("groups.new.handles.placeholder"),
                        accessibilityHint: L10n.t("groups.new.handles.a11yHint")
                    )
                    HStack(spacing: SLSpacing.sm) {
                        SLButton(
                            L10n.t("groups.members.add"),
                            variant: .secondary,
                            size: .compact,
                            icon: "person.badge.plus",
                            isLoading: viewModel.isSaving,
                            isEnabled: viewModel.canAddMembers,
                            asyncAction: { await viewModel.addMembers() }
                        )
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            viewModel.requestDeletion(group)
                        } label: {
                            Label(L10n.t("groups.delete"), systemImage: "trash")
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.danger)
                        }
                        .accessibilityLabel(Text(L10n.t("groups.delete.a11yLabel", group.name)))
                    }
                }
            }
        }
    }

    /// People ticked for a group that does not exist yet, each with a way out.
    private func pickedPeople(_ people: [UserSummary], remove: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            ForEach(people) { person in
                HStack(spacing: SLSpacing.sm) {
                    SLAvatar(
                        url: person.avatarURL,
                        initials: person.initials,
                        size: .sm,
                        isVerified: person.isVerified,
                        displayName: person.displayName
                    )
                    Text(person.displayName)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)
                    Text(person.atHandle)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        remove(person.handle)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(SLColor.textMuted)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text(L10n.t("groups.member.remove.a11yLabel", person.displayName)))
                }
            }
        }
    }

    private func membersRow(_ group: UserGroup, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            ForEach(group.members) { member in
                HStack(spacing: SLSpacing.sm) {
                    SLAvatar(
                        url: member.avatarURL,
                        initials: member.initials,
                        size: .sm,
                        isVerified: member.isVerified,
                        displayName: member.displayName
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(member.displayName)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(1)
                        Text(member.atHandle)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if editable {
                        Button {
                            Task { await viewModel.removeMember(member.handle, from: group) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(SLColor.textMuted)
                                .frame(width: 32, height: 28)
                                .contentShape(Rectangle())
                        }
                        .disabled(viewModel.isSaving)
                        .accessibilityLabel(Text(L10n.t("groups.member.remove.a11yLabel", member.displayName)))
                    }
                }
            }
        }
    }
}
