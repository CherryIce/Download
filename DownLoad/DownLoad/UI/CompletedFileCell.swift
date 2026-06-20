//
//  CompletedFileCell.swift
//  DownLoad
//

import UIKit

/// 已完成文件列表单元格
class CompletedFileCell: UITableViewCell {

    static let reuseIdentifier = "CompletedFileCell"

    // MARK: - UI Components
    private let iconImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.tintColor = .systemBlue
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let sizeLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let formatTagLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabel
        label.backgroundColor = UIColor.dynamic(light: UIColor(hex: "f0f0f0"), dark: UIColor(hex: "2c2c2e"))
        label.textAlignment = .center
        label.layer.cornerRadius = 3
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let dateLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let separatorView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.dynamic(light: UIColor(hex: "e0e0e0"), dark: UIColor(hex: "3a3a3a"))
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    // MARK: - Initialization
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup
    private func setupUI() {
        contentView.addSubview(iconImageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(sizeLabel)
        contentView.addSubview(formatTagLabel)
        contentView.addSubview(dateLabel)
        contentView.addSubview(separatorView)

        NSLayoutConstraint.activate([
            // 图标
            iconImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 36),
            iconImageView.heightAnchor.constraint(equalToConstant: 36),

            // 文件名
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: sizeLabel.leadingAnchor, constant: -8),

            // 文件大小（右对齐）
            sizeLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // 格式标签
            formatTagLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            formatTagLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            formatTagLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            formatTagLabel.heightAnchor.constraint(equalToConstant: 18),

            // 完成时间
            dateLabel.centerYAnchor.constraint(equalTo: formatTagLabel.centerYAnchor),
            dateLabel.leadingAnchor.constraint(equalTo: formatTagLabel.trailingAnchor, constant: 8),
            dateLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),

            // 底部分隔线
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    // MARK: - Configuration
    func configure(with item: CompletedFileItem) {
        iconImageView.image = UIImage(systemName: iconForFormat(item.format))
        nameLabel.text = item.fileName
        sizeLabel.text = item.formattedFileSize

        let ext = item.fileExtension
        formatTagLabel.text = ext.isEmpty ? Strings.Label.file : ext

        dateLabel.text = item.formattedCompletedAt ?? ""
    }

    // MARK: - Helpers
    private func iconForFormat(_ format: VideoFormat) -> String {
        switch format {
        case .mp4, .webm, .mkv, .flv, .mov:
            return "film"
        case .m3u8:
            return "play.rectangle"
        case .thunder, .thunderP2P:
            return "bolt"
        case .magnet:
            return "magnet"
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconImageView.image = nil
        nameLabel.text = nil
        sizeLabel.text = nil
        formatTagLabel.text = nil
        dateLabel.text = nil
    }
}
