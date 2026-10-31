import Foundation

/// Seed folders, per-type schemas and documents, written into an empty database on first launch
/// (`LibraryDatabase`). Command-line harnesses use them directly.
nonisolated enum SampleData {
    /// A folder and the documents seeded into it.
    struct Seed {
        var folder: DocumentFolder
        var docs: [Document]
    }

    static func folders() -> [Seed] {
        [inbox, invoices, letters, quotes, receipts, contracts]
    }

    // MARK: Unclassified

    static let inboxFields: [SchemaField] = [
        SchemaField(key: MetaKey.kind, label: "File Type", width: 130),
        SchemaField(key: MetaKey.pages, label: "Pages", type: .integer, width: 70),
        SchemaField(key: MetaKey.md5, label: "MD5", width: 250),
        SchemaField(key: MetaKey.added, label: "Date Added", type: .timestamp, width: 175),
        SchemaField(key: MetaKey.size, label: "Size", type: .integer, width: 90),
    ]

    private static var inbox: Seed {
        Seed(folder: .inbox, docs: [
            Document(name: "Scan_2024-06-14_0931.pdf", kind: "PDF Document", added: stamp("14 Jun 2024 09:31"),
                     sizeBytes: 284_000, pages: 2, md5: "9f2a7c1be4d80a36f5b8e1c4d27a9f63",
                     content: .printed(PrintedPage(style: .invoice, from: "Brightwater Plumbing", date: "12 Jun 2024", amount: "$1,248.50",
                                                   lines: ["Hot water unit — supply & install", "Labour (3.5 hrs)", "Sundries",
                                                           "Payment due 28 Jun 2024", "BPAY Biller 247164 · Ref 5829 1047 22"]))),
            Document(name: "letter_strata_notice.pdf", kind: "PDF Document", added: stamp("13 Jun 2024 16:02"),
                     sizeBytes: 121_000, pages: 1, md5: "4b1d77e0a9c3f58261ad0e9b7c4f2a18",
                     content: .printed(PrintedPage(style: .letter, from: "Meridian Strata Management", date: "10 Jun 2024",
                                                   to: "The Owner, Lot 14", subject: "Notice of Annual General Meeting",
                                                   paragraph: "We write to advise that the Annual General Meeting for the Owners Corporation will be held on 3 July 2024 at 6:00 pm."))),
            Document(name: "quote_landscaping_v2.pdf", kind: "PDF Document", added: stamp("13 Jun 2024 11:18"),
                     sizeBytes: 402_000, pages: 3, md5: "e7c4a91f0b2d6538a1c9f74e3b8d05a2",
                     content: .printed(PrintedPage(style: .quote, from: "Greenline Gardens", date: "11 Jun 2024", amount: "$6,420.00",
                                                   lines: ["Quote Q-2041 · valid until 11 Jul 2024", "Site preparation & removal",
                                                           "Turf supply (120 m²)", "Irrigation system", "3-month establishment care"]))),
            Document(name: "woolworths_receipt.jpg", kind: "JPEG Image", added: stamp("12 Jun 2024 18:44"),
                     sizeBytes: 1_200_000, pages: 1, md5: "1a6f3b9d8e2c47015a9b0d3f6e8c2147",
                     content: .printed(PrintedPage(style: .receipt, from: "Woolworths Metro", date: "12 Jun 2024", amount: "$48.27",
                                                   lines: ["Groceries", "GST included"]))),
            Document(name: "IMG_4471.HEIC", kind: "HEIF Image", added: stamp("11 Jun 2024 14:09"),
                     sizeBytes: 2_800_000, pages: 1, md5: "c83e5a0146fb29d7e4b18c6a3f905d2e",
                     content: .printed(PrintedPage(style: .receipt, from: "Bunnings Warehouse", date: "11 Jun 2024", amount: "$112.90",
                                                   lines: ["Hardware", "Garden"]))),
            Document(name: "payslip_2024-06-15.pdf", kind: "PDF Document", added: stamp("10 Jun 2024 12:20"),
                     sizeBytes: 88_000, pages: 1, md5: "a3f19c0d7e5b42816c9e0f2d4b7a1c58",
                     content: .printed(PrintedPage(style: .letter, from: "Northwind Logistics — Payroll", date: "15 Jun 2024",
                                                   to: "Employee: Sam Taylor (ID 20417)", subject: "Payslip — pay period 1 to 15 Jun 2024",
                                                   paragraph: "Gross pay $4,250.00. Tax withheld $1,020.00. Superannuation $488.75. Net pay $3,230.00 paid to account ending 4471."))),
            Document(name: "service_agreement_draft.docx", kind: "Word Document", added: stamp("10 Jun 2024 10:55"),
                     sizeBytes: 64_000, pages: 5, md5: "5d9c1e7a4b206f83d0a7e91c4f63b8a0",
                     content: .printed(PrintedPage(style: .contract, from: "Aperture Consulting Pty Ltd", date: "9 Jun 2024",
                                                   to: "Client", subject: "Master Services Agreement",
                                                   paragraph: "This Agreement sets out the terms under which the Supplier will provide consulting services to the Client."))),
        ])
    }

    // MARK: Invoices

    private static var invoices: Seed {
        Seed(folder: DocumentFolder(id: "invoices", name: "Invoices",
                       description: "Bills requesting payment for goods or services, with an amount due, a due date and payment details such as BPAY or bank transfer.",
                       fields: [
            SchemaField(key: "vendor", label: "Vendor", type: .string, width: 170, description: "The business or individual that issued the invoice. Usually appears at the top of the document as a company name and logo, or in the 'From' / 'Bill From' section. Capture the trading name exactly as written, excluding the ABN and address."),
            SchemaField(key: "dueDate", label: "Due Date", type: .date, width: 120, description: "The date by which payment must be received, often labelled 'Due Date', 'Payment Due' or 'Pay By'. If only an issue date and payment terms (e.g. 'Net 14') are given, calculate the due date from those. Return in DD Mon YYYY format."),
            SchemaField(key: "amount", label: "Amount", type: .decimal, width: 110, description: "The total amount payable in the invoice currency, inclusive of GST and any surcharges. Use the final 'Total', 'Amount Due' or 'Balance Due' figure rather than the subtotal. Strip currency symbols and thousands separators."),
            SchemaField(key: "biller", label: "BPAY Biller", type: .string, width: 130, description: "The BPAY Biller Code — a short numeric code (typically 3–6 digits) shown next to the BPAY logo in the payment options section. Do not confuse it with the reference number."),
            SchemaField(key: "reference", label: "Reference", type: .string, width: 130, description: "The customer reference or BPAY reference number used to identify this specific invoice when paying. Often labelled 'Ref', 'Reference No.' or 'Customer Reference' and may include hyphens or spaces."),
            SchemaField(key: "bsbAccount", label: "BSB / Account", type: .string, width: 150, description: "Bank details for electronic funds transfer: the 6-digit BSB and the account number, usually presented together for direct deposit. Capture both as 'BSB / Account'. Leave blank if only BPAY is offered."),
        ]), docs: [
            invoice("Brightwater_INV-20418.pdf", "Brightwater Plumbing", "28 Jun 2024", "$1,248.50", "247164", "5829 1047 22", "062-018 / 1047 8821", ["Hot water unit — supply & install", "Labour (3.5 hrs)", "Sundries & fittings"]),
            invoice("EnergyAustralia_Q2.pdf", "EnergyAustralia", "02 Jul 2024", "$486.21", "9421", "4471 9928 01", "032-002 / 4471 9928", ["Electricity usage — 91 days", "Supply charge", "Solar feed-in credit"]),
            invoice("Telstra_June.pdf", "Telstra", "19 Jun 2024", "$118.00", "5588", "1029 4471 88", "—", ["Mobile plan", "Data add-on", "Device repayment"]),
            invoice("Aperture_INV-0091.pdf", "Aperture Consulting", "05 Jul 2024", "$8,800.00", "330021", "2024-0091", "082-991 / 5510 2241", ["Discovery & strategy", "Design system build", "Implementation support"]),
            invoice("CityCouncil_Rates.pdf", "City of Melbourne", "30 Jun 2024", "$742.65", "118822", "RATE-44120", "063-000 / 1188 2204", ["Quarterly rates", "Waste service charge"]),
            invoice("AcmeOffice_4471.pdf", "Acme Office Supplies", "21 Jun 2024", "$329.40", "20041", "INV-4471", "012-444 / 9921 0048", ["A4 paper (10 reams)", "Toner cartridge", "Misc stationery"]),
            invoice("WaterCorp_Q2.pdf", "Yarra Valley Water", "08 Jul 2024", "$211.18", "77120", "WC-99214", "063-115 / 7712 0099", ["Water usage", "Sewerage", "Drainage"]),
            invoice("Cleaning_June.pdf", "Sparkle Commercial Clean", "25 Jun 2024", "$560.00", "44219", "SC-2024-06", "083-004 / 4421 9007", ["Weekly office clean ×4", "Carpet steam clean"]),
        ])
    }

    // MARK: Letters

    private static var letters: Seed {
        Seed(folder: DocumentFolder(id: "letters", name: "Letters",
                       description: "Correspondence addressed to a person or household, such as notices and official letters, that doesn't ask for payment.",
                       fields: [
            SchemaField(key: "sender", label: "Sender", type: .string, width: 220, description: "The person or organisation that wrote the letter. Look at the letterhead, the return address, or the signature block at the end. Prefer the organisation name where the letter is on official letterhead."),
            SchemaField(key: "recipient", label: "Recipient", type: .string, width: 200, description: "The intended addressee of the letter, taken from the inside address near the top or the salutation ('Dear ...'). Capture the name or role as written, e.g. 'The Owner, Lot 14'."),
            SchemaField(key: "date", label: "Date", type: .date, width: 130, description: "The date the letter was written, usually printed above or below the sender's address. Ignore any dates mentioned within the body that refer to events. Return in DD Mon YYYY format."),
        ]), docs: [
            letter("AGM_notice_2024.pdf", "Meridian Strata Management", "The Owner, Lot 14", "10 Jun 2024", "Notice of Annual General Meeting", "We write to advise that the Annual General Meeting for the Owners Corporation will be held on 3 July 2024 at 6:00 pm in the building common room."),
            letter("ATO_assessment.pdf", "Australian Taxation Office", "Mr J. Whitman", "28 May 2024", "Notice of Assessment 2023–24", "Your income tax return for the year ended 30 June has been processed. This notice sets out the result of your assessment."),
            letter("bank_rate_change.pdf", "Commonwealth Bank", "Account Holder", "15 May 2024", "Change to your home loan interest rate", "We are writing to let you know that the variable interest rate on your home loan will change effective 1 June 2024."),
            letter("school_enrolment.pdf", "Fitzroy Primary School", "Parents & Guardians", "02 May 2024", "Confirmation of Enrolment", "We are pleased to confirm your child's enrolment for the upcoming academic year. Please find orientation details enclosed."),
        ])
    }

    // MARK: Quotes

    private static var quotes: Seed {
        Seed(folder: DocumentFolder(id: "quotes", name: "Quotes",
                       description: "Price quotations from suppliers for proposed work or goods, with a quoted total and an expiry date.",
                       fields: [
            SchemaField(key: "vendor", label: "Vendor", type: .string, width: 200, description: "The supplier providing the quote, typically shown on the letterhead or in a 'Prepared by' section. Capture the trading name only."),
            SchemaField(key: "amount", label: "Amount", type: .decimal, width: 120, description: "The total quoted price including GST. If the quote presents a range or optional line items, capture the headline total the customer would pay to accept the full quote. Strip currency symbols."),
            SchemaField(key: "validUntil", label: "Valid Until", type: .date, width: 130, description: "The expiry date of the quote, after which the pricing is no longer guaranteed. Often labelled 'Valid Until', 'Expires' or 'Quote valid for 30 days' (calculate from the issue date if expressed as a duration)."),
            SchemaField(key: "quoteNo", label: "Quote No.", type: .string, width: 130, description: "The supplier's quotation reference number, e.g. 'Q-2041' or 'Quote #8841'. Used to identify the quote in later correspondence."),
        ]), docs: [
            quote("Greenline_landscaping.pdf", "Greenline Gardens", "$6,420.00", "11 Jul 2024", "Q-2041", ["Site preparation & removal", "Turf supply (120 m²)", "Irrigation system", "3-month establishment care"]),
            quote("RoofRight_reroof.pdf", "RoofRight Pty Ltd", "$18,950.00", "30 Jun 2024", "RR-8841", ["Remove existing tiles", "Sarking & battens", "Colorbond sheeting", "Gutters & downpipes"]),
            quote("BrightSpark_rewire.pdf", "BrightSpark Electrical", "$3,275.00", "05 Jul 2024", "BS-1192", ["Switchboard upgrade", "Rewire ground floor", "Safety switch & testing"]),
        ])
    }

    // MARK: Receipts

    private static var receipts: Seed {
        Seed(folder: DocumentFolder(id: "receipts", name: "Receipts",
                       description: "Proof of payment for a completed purchase, such as a shop, fuel or ride receipt, showing the total paid.",
                       fields: [
            SchemaField(key: "merchant", label: "Merchant", type: .string, width: 180, description: "The store or business where the purchase was made, taken from the header of the receipt. Use the consumer-facing brand name (e.g. 'Woolworths Metro') rather than the legal entity."),
            SchemaField(key: "date", label: "Date", type: .date, width: 120, description: "The transaction date printed on the receipt, typically near the time and register/terminal number. Return in DD Mon YYYY format."),
            SchemaField(key: "amount", label: "Amount", type: .decimal, width: 110, description: "The total amount paid, taken from the 'Total' line (not the subtotal or any individual item). Includes GST. Strip currency symbols."),
            SchemaField(key: "gst", label: "GST", type: .decimal, width: 90, description: "The GST (tax) component of the purchase, usually shown on a dedicated 'GST' or 'Tax' line near the total. If not itemised, it can be derived as 1/11th of the total for GST-inclusive Australian receipts."),
            SchemaField(key: "category", label: "Category", type: .string, width: 140, description: "A spending category inferred from the merchant and items, e.g. Groceries, Fuel, Hardware, Meals. Choose a single concise label suitable for expense reporting."),
        ]), docs: [
            receipt("woolworths_0612.jpg", "Woolworths Metro", "12 Jun 2024", "$48.27", "$4.39", "Groceries"),
            receipt("bunnings_0611.jpg", "Bunnings Warehouse", "11 Jun 2024", "$112.90", "$10.26", "Hardware"),
            receipt("shell_fuel.jpg", "Shell Coles Express", "09 Jun 2024", "$84.10", "$7.65", "Fuel"),
            receipt("officeworks.jpg", "Officeworks", "07 Jun 2024", "$56.00", "$5.09", "Office"),
            receipt("cafe_lune.jpg", "Café Lune", "06 Jun 2024", "$23.50", "$2.14", "Meals"),
            receipt("uber_trip.pdf", "Uber", "05 Jun 2024", "$31.20", "$2.84", "Transport"),
            receipt("chemist.jpg", "Chemist Warehouse", "04 Jun 2024", "$19.95", "$1.81", "Health"),
            receipt("kmart.jpg", "Kmart", "03 Jun 2024", "$67.00", "$6.09", "Household"),
            receipt("dan_murphys.jpg", "Dan Murphy's", "01 Jun 2024", "$58.00", "$5.27", "Other"),
            receipt("jbhifi.pdf", "JB Hi-Fi", "29 May 2024", "$249.00", "$22.64", "Electronics"),
            receipt("coles_0528.jpg", "Coles", "28 May 2024", "$92.40", "$8.40", "Groceries"),
            receipt("petbarn.jpg", "Petbarn", "26 May 2024", "$41.80", "$3.80", "Pets"),
        ])
    }

    // MARK: Contracts

    private static var contracts: Seed {
        Seed(folder: DocumentFolder(id: "contracts", name: "Contracts",
                       description: "Agreements between two parties, such as service agreements and leases, with a start date, a term and a value.",
                       fields: [
            SchemaField(key: "party", label: "Counterparty", type: .string, width: 200, description: "The other party to the agreement (i.e. not the document owner) — typically the supplier, lessor, or service provider named in the opening 'between ... and ...' clause. Capture the full legal entity name including 'Pty Ltd' where present."),
            SchemaField(key: "effective", label: "Effective", type: .date, width: 120, description: "The commencement or effective date of the contract, often in the recitals or the 'Term' clause. If a separate signing date exists, prefer the stated effective/commencement date. Return in DD Mon YYYY format."),
            SchemaField(key: "term", label: "Term", type: .string, width: 120, description: "The duration of the agreement as written, e.g. '12 months', '24 months', or 'ongoing until terminated'. Capture the stated length rather than calculating an end date."),
            SchemaField(key: "value", label: "Value", type: .decimal, width: 120, description: "The total contract value, or for recurring payments the amount of one payment. The period it covers goes in the Period field."),
            SchemaField(key: "period", label: "Period", type: .string, width: 100, description: "How often the Value is paid, such as month, quarter or year. Leave empty when the Value is a one-off total."),
        ]), docs: [
            contract("MSA_Aperture.pdf", "Aperture Consulting Pty Ltd", "01 Jul 2024", "12 months", "$96,000.00", nil, "Master Services Agreement", "This Agreement sets out the terms under which the Supplier will provide consulting services to the Client over the term, for a total fee of $96,000.00."),
            contract("Lease_Smith_St.pdf", "Northside Property Group", "15 May 2024", "24 months", "$2,650", "month", "Commercial Lease — 88 Smith St", "The Lessor leases the premises to the Lessee for the term, at a rent of $2,650 per month and on the conditions set out in this lease."),
        ])
    }

    // MARK: Builders

    private static func invoice(_ name: String, _ vendor: String, _ dueDate: String, _ amount: String, _ biller: String,
                                _ reference: String, _ bsbAccount: String, _ lines: [String]) -> Document {
        Document(name: name, kind: "PDF Document", added: day(dueDate), sizeBytes: randomSize(), pages: 1,
                 values: ["vendor": vendor, "dueDate": dueDate, "amount": number(amount), "biller": biller,
                          "reference": reference, "bsbAccount": bsbAccount],
                 content: .printed(PrintedPage(style: .invoice, from: vendor, date: dueDate, amount: amount, lines: lines)))
    }

    private static func letter(_ name: String, _ sender: String, _ recipient: String, _ date: String,
                               _ subject: String, _ paragraph: String) -> Document {
        Document(name: name, kind: "PDF Document", added: day(date), sizeBytes: randomSize(), pages: 1,
                 values: ["sender": sender, "recipient": recipient, "date": date],
                 content: .printed(PrintedPage(style: .letter, from: sender, date: date, to: recipient,
                                               subject: subject, paragraph: paragraph)))
    }

    private static func quote(_ name: String, _ vendor: String, _ amount: String, _ validUntil: String,
                              _ quoteNo: String, _ lines: [String]) -> Document {
        Document(name: name, kind: "PDF Document", added: day(validUntil), sizeBytes: randomSize(), pages: 1,
                 values: ["vendor": vendor, "amount": number(amount), "validUntil": validUntil, "quoteNo": quoteNo],
                 content: .printed(PrintedPage(style: .quote, from: vendor, date: validUntil, amount: amount, lines: lines)))
    }

    private static func receipt(_ name: String, _ merchant: String, _ date: String, _ amount: String,
                                _ gst: String, _ category: String) -> Document {
        Document(name: name, kind: name.hasSuffix(".pdf") ? "PDF Document" : "JPEG Image", added: day(date),
                 sizeBytes: randomSize(), pages: 1,
                 values: ["merchant": merchant, "date": date, "amount": number(amount), "gst": number(gst), "category": category],
                 content: .printed(PrintedPage(style: .receipt, from: merchant, date: date, amount: amount,
                                               lines: [category, "GST " + gst])))
    }

    private static func contract(_ name: String, _ party: String, _ effective: String, _ term: String, _ value: String,
                                 _ period: String?, _ subject: String, _ paragraph: String) -> Document {
        var values = ["party": party, "effective": effective, "term": term, "value": number(value)]
        values["period"] = period
        return Document(name: name, kind: "PDF Document", added: day(effective), sizeBytes: randomSize(), pages: 1,
                        values: values,
                        content: .printed(PrintedPage(style: .contract, from: party, date: effective,
                                                      subject: subject, paragraph: paragraph)))
    }

    private static func randomSize() -> Int64 { Int64.random(in: 40...940) * 1000 }

    /// Numeric fields store only the number ("$1,248.50" → "1,248.50"); the printed pages keep the currency.
    private static func number(_ amount: String) -> String {
        FieldType.decimal.convertedValue(amount) ?? ""
    }

    private static func day(_ string: String) -> Date {
        DateFormatter.documentDay.date(from: string) ?? .now
    }

    private static func stamp(_ string: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy HH:mm"
        return f.date(from: string) ?? .now
    }
}
