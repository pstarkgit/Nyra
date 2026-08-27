import SwiftUI

struct ApprovalView: View {
    let approval: CodexApproval
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approval required", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(approval.summary).font(.caption)
            if let details = approval.details {
                Text(details)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            HStack {
                Button("Deny", role: .cancel, action: deny)
                Spacer()
                Button("Approve Once", action: approve)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
