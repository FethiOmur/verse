import Foundation

/// One test language: locale, `say` voices (alternated per question) and 20 scripted questions.
/// Scripts contain no digits so WER is not distorted by number formatting.
struct LangSpec: Sendable {
    let key: String            // "en", "it", "tr"
    let localeID: String       // "en_US"
    let voices: [String]       // `say -v` names, used round-robin
    let questions: [String]
}

enum Corpus {
    static let en = LangSpec(
        key: "en", localeID: "en_US", voices: ["Albert"],
        questions: [
            "What is the main risk in the current delivery timeline?",
            "Can you walk us through how the pricing model works?",
            "Do you think the team can ship before the end of the quarter?",
            "How many people are working on the integration right now?",
            "Why did we decide to move the launch to November?",
            "Is the budget approved for the new contractor?",
            "Who is responsible for the customer onboarding flow?",
            "Would it make sense to start with a smaller pilot?",
            "When can we expect the first version of the report?",
            "Have you already talked to the security team about this?",
            "What happens if the vendor misses the deadline?",
            "Are we confident that the data migration will work?",
            "Could you explain why the latency is higher on mobile?",
            "Which customers are most affected by this change?",
            "Did the last release include the fix for the login problem?",
            "How does your approach compare to what we do today?",
            "Is there anything blocking you from starting next week?",
            "What would you do differently if you had more time?",
            "Do we have a backup plan if the contract falls through?",
            "Where do you see the biggest opportunity for the next year?",
        ])

    // Many Italian yes/no questions have statement word order (intonation only): 6, 8, 10, 12, 15, 17, 18, 19.
    static let it = LangSpec(
        key: "it", localeID: "it_IT", voices: ["Alice", "Eddy (İtalyanca (İtalya))"],
        questions: [
            "Qual è il rischio principale nel piano di consegna attuale?",
            "Puoi spiegarci come funziona il modello di prezzi?",
            "Pensi che il team riesca a finire prima della fine del trimestre?",
            "Quante persone lavorano adesso sull'integrazione?",
            "Perché abbiamo deciso di spostare il lancio a novembre?",
            "Il budget per il nuovo collaboratore è stato approvato?",
            "Chi è responsabile del processo di accoglienza dei clienti?",
            "Ha senso partire con un progetto pilota più piccolo?",
            "Quando possiamo aspettarci la prima versione del rapporto?",
            "Hai già parlato con il gruppo della sicurezza di questo punto?",
            "Cosa succede se il fornitore non rispetta la scadenza?",
            "Siamo sicuri che la migrazione dei dati funzionerà?",
            "Potresti spiegare perché la latenza è più alta sul telefono?",
            "Quali clienti sono più colpiti da questa modifica?",
            "L'ultima versione include la correzione del problema di accesso?",
            "Come si confronta il tuo metodo con quello che facciamo oggi?",
            "Ti blocca qualcosa dal cominciare la settimana prossima?",
            "Hai tutto quello che ti serve per iniziare?",
            "Abbiamo un piano di riserva se il contratto salta?",
            "Dove vedi la più grande opportunità per il prossimo anno?",
        ])

    // Turkish: mı / mi / mu / mü particles in 3, 6, 8, 10, 12, 13, 17, 19 and others.
    static let tr = LangSpec(
        key: "tr", localeID: "tr_TR", voices: ["Yelda"],
        questions: [
            "Mevcut teslim planındaki en büyük risk nedir?",
            "Fiyatlandırma modelinin nasıl çalıştığını anlatabilir misiniz?",
            "Ekip bunu çeyrek sonuna kadar yetiştirebilir mi?",
            "Şu anda entegrasyonda kaç kişi çalışıyor?",
            "Lansmanı neden kasıma ertelemeye karar verdik?",
            "Yeni yüklenici için bütçe onaylandı mı?",
            "Müşteri karşılama sürecinden kim sorumlu?",
            "Daha küçük bir pilotla başlamak mantıklı mı?",
            "Raporun ilk sürümünü ne zaman bekleyebiliriz?",
            "Bu konuyu güvenlik ekibiyle zaten konuştun mu?",
            "Tedarikçi teslim tarihini kaçırırsa ne olur?",
            "Veri taşımanın çalışacağından emin miyiz?",
            "Karar bugün mü verilecek?",
            "Bu değişiklikten en çok hangi müşteriler etkileniyor?",
            "Son sürümde giriş sorununun düzeltmesi var mıydı?",
            "Senin yaklaşımın bugün yaptığımızla nasıl karşılaştırılıyor?",
            "Gelecek hafta başlamana engel olan bir şey var mı?",
            "Daha fazla vaktin olsaydı neyi farklı yapardın?",
            "Fiyat müşteriye çok yüksek gelmiyor mu?",
            "Önümüzdeki yıl en büyük fırsatı nerede görüyorsun?",
        ])

    /// Control: same English script, a higher-quality voice, to separate TTS quality from recognizer quality.
    static let enControl = LangSpec(key: "en-samantha", localeID: "en_US", voices: ["Samantha"], questions: en.questions)

    static let all: [LangSpec] = [en, it, tr]
}
