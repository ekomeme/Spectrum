import AppKit
import AVFoundation

/// Sheet with a searchable list of installed AU effects.
final class PluginPickerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let all: [AVAudioUnitComponent]
    private var filtered: [AVAudioUnitComponent]
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    var onPick: ((AVAudioUnitComponent) -> Void)?

    init(components: [AVAudioUnitComponent]) {
        all = components
        filtered = components
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        searchField.placeholderString = "Search plugins (e.g. Pro-Q)"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Plugin"
        nameColumn.width = 260
        let makerColumn = NSTableColumn(identifier: .init("maker"))
        makerColumn.title = "Manufacturer"
        makerColumn.width = 180
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(makerColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(confirm)
        tableView.target = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(confirm)
        addButton.keyEquivalent = "\r"
        addButton.isEnabled = false

        let buttons = NSStackView(views: [NSView(), cancel, addButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Choose an Audio Unit plugin")
        title.font = .boldSystemFont(ofSize: 14)
        title.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.initialFirstResponder = searchField
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let component = filtered[row]
        let text = tableColumn?.identifier.rawValue == "maker" ? component.manufacturerName : component.name
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(field)
            view.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }()
        cell.textField?.stringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        addButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            filtered = all
        } else {
            filtered = all.filter { $0.name.lowercased().contains(query) || $0.manufacturerName.lowercased().contains(query) }
        }
        tableView.reloadData()
        if filtered.count == 1 { tableView.selectRowIndexes([0], byExtendingSelection: false) }
        addButton.isEnabled = tableView.selectedRow >= 0
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), tableView.selectedRow >= 0 {
            confirm()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            window?.makeFirstResponder(tableView)
            if tableView.selectedRow < 0, filtered.count > 0 { tableView.selectRowIndexes([0], byExtendingSelection: false) }
            return true
        }
        return false
    }

    // MARK: Actions

    @objc private func confirm() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count, let window else { return }
        let component = filtered[row]
        window.sheetParent?.endSheet(window, returnCode: .OK)
        onPick?(component)
    }

    @objc private func cancel(_ sender: Any?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: .cancel)
    }
}
