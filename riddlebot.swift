#!/usr/bin/swift

import Foundation



extension URLSession {
	
	func synchronousDataTask(with request: URLRequest) throws -> (data: Data?, response: URLResponse?) {
		let semaphore = DispatchSemaphore(value: 0)
		
		var responseData: Data?
		var theResponse: URLResponse?
		var theError: Error?
		
		dataTask(with: request) { data, response, error in
			responseData = data
			theResponse = response
			theError = error
			
			semaphore.signal()
		}.resume()
		
		_ = semaphore.wait(timeout: .distantFuture)
		
		if let error = theError {
			throw error
		}
		
//		print("request: \(request.httpBody?.base64EncodedString())")
//		print("data: \(responseData?.base64EncodedString())")
		
		return (data: responseData, response: theResponse)
	}
	
	func synchronousFetch<ObjectType : Decodable>(request: URLRequest) throws -> ObjectType {
		let (dataO, response) = try synchronousDataTask(with: request)
		guard let data = dataO, let httpResponse = response as? HTTPURLResponse else {
			throw NSError(domain: "riddlebot", code: 1, userInfo: nil)
		}
		guard 200..<300 ~= httpResponse.statusCode else {
			throw NSError(domain: "riddlebot", code: 2, userInfo: ["Fetched Data": data])
		}
		let jsonDecoder = JSONDecoder()
		return try jsonDecoder.decode(ObjectType.self, from: data)
	}
	
	func synchronousFetch<ObjectType : Decodable>(url: URL) throws -> ObjectType {
		return try synchronousFetch(request: URLRequest(url: url))
	}
	
	func synchronousFetch<InputObjectType : Encodable, OutputObjectType : Decodable>(url: URL, httpMethod: String, httpBodyObject: InputObjectType) throws -> OutputObjectType {
		let request = try URLRequest(url: url, httpMethod: httpMethod, httpBodyObject: httpBodyObject)
		return try synchronousFetch(request: request)
	}
	
}

extension URLRequest {
	
	init<ObjectType : Encodable>(url: URL, httpMethod m: String, httpBodyObject: ObjectType) throws {
		self.init(url: url)
		
		httpMethod = m
		
		let jsonEncoder = JSONEncoder()
		httpBody = try jsonEncoder.encode(httpBodyObject)
		addValue("application/json", forHTTPHeaderField: "Content-Type")
	}
	
}


struct LoginRequest : Encodable {
	
	var login: String
	
}

struct LoginResponse : Decodable {
	
	var message: String
	var riddlePath: String
	
}

struct RiddleAnswer : Codable {
	
	var answer: String
	
}

struct Riddle : Decodable {
	
	enum RiddleType : Decodable {
		
		case reverse(text: String)
		case rot13(text: String)
		case caesar(text: String, key: Int)
		case vigenere(text: String, key: [Int])
		case caesarUnknownKey(text: String)
		case vigenereUnknownKey(text: String)
		
		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let type = try container.decode(String.self, forKey: .riddleType)
			let text = try container.decode(String.self, forKey: .riddleText)
			switch type {
			case "reverse":  self = .reverse(text: text)
			case "rot13":    self = .rot13(text: text)
			case "caesar":
				do {
					self = try .caesar(text: text, key: container.decode(Int.self, forKey: .riddleKey))
				} catch {
					/* We assume it’s the missing key error… */
					self = .caesarUnknownKey(text: text)
				}
			case "vigenere":
				do {
					self = try .vigenere(text: text, key: container.decode([Int].self, forKey: .riddleKey))
				} catch {
					/* We assume it’s the missing key error… */
					self = .vigenereUnknownKey(text: text)
				}
			default: throw NSError(domain: "riddlebot", code: 3, userInfo: ["Unknown type": type, "Container": container])
			}
		}
		
		private enum CodingKeys : String, CodingKey {
			case riddleType
			case riddleText
			case riddleKey
		}
		
	}
	
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		message         = try container.decode(String.self, forKey: .message)
		riddlePath      = try container.decode(String.self, forKey: .riddlePath)
		exampleResponse = try container.decode(RiddleAnswer.self, forKey: .exampleResponse)
		riddleType      = try RiddleType(from: decoder)
	}
	
	var message: String
	var riddlePath: String
	var exampleResponse: RiddleAnswer
	var riddleType: RiddleType
	
	private enum CodingKeys : String, CodingKey {
		case message
		case riddlePath
		case exampleResponse
	}
	
}

struct RiddleAnswerResponse : Decodable {
	
	enum RiddleAnswerResponseResult : String, Codable {
		
		case correct
		
	}
	
	var result: RiddleAnswerResponseResult
	var nextRiddlePath: String?
	
}

func rot13(_ str: String) -> String {
	return caesar(str, 13)
}

func caesar(_ str: String, _ delta: CChar) -> String {
	return vigenere(str, [delta])
}

func vigenere(_ str: String, _ deltas: [CChar]) -> String {
	assert(deltas.count > 0)
	var ret = [CChar]()
	
	var i = 0
	let a = "a".utf8CString[0], z = "z".utf8CString[0]
	let A = "A".utf8CString[0], Z = "Z".utf8CString[0]
	let space = (z - a + 1), SPACE = (Z - A + 1)
	for c in str.utf8CString {
		switch c {
		case a...z: ret.append((c + deltas[i] - a + space)%space + a); i = (i + 1)%deltas.count
		case A...Z: ret.append((c + deltas[i] - A + SPACE)%SPACE + A); i = (i + 1)%deltas.count
		default: ret.append(c)
		}
	}
	return String(utf8String: ret)!
}

func caesarUnknownKey(_ str: String) throws -> String {
	for k in 0..<26 {
		let decryptedTest = caesar(str, CChar(k))
		/* VERY basic verification of correct decryption ^^ */
		if decryptedTest.lowercased().contains(" a ") {
			return decryptedTest
		}
	}
	throw NSError(domain: "riddlebot", code: 4, userInfo: nil)
}

//var n = 0
//let q = DispatchQueue(label: "hello")
class FindVigenereOperation : Operation {
	
	let str: String
	let minK1: Int
	let maxK1: Int
	let dictionary: Set<String>
	
	let foundKey: (_ key: [CChar], _ message: String) -> Void
	
	init(string: String, minK1 m: Int, maxK1 M: Int, dictionary d: Set<String>, foundKeyHandler: @escaping (_ key: [CChar], _ message: String) -> Void) {
		str = string
		minK1 = m
		maxK1 = M
		dictionary = d
		foundKey = foundKeyHandler
		super.init()
	}
	
	override func main() {
		/* We know the key size is 4 */
		for k1 in minK1..<maxK1 {
			for k2 in 0..<26 {
				for k3 in 0..<26 {
					for k4 in 0..<26 {
//						q.sync{ n+=1 }
						if isCancelled {return}
						let k = [-CChar(k1), -CChar(k2), -CChar(k3), -CChar(k4)]
						let decryptedTest = vigenere(str, k)
						let decryptedTestWords = decryptedTest.split(separator: " ").map{ String($0).lowercased() }
						let matchingWordsCount = decryptedTestWords.reduce(0, { $0 + (dictionary.contains($1) ? 1 : 0) })
//						if matchingWordsCount > 0 {print(matchingWordsCount)}
//						print("HHH: \(matchingWordsCount)")
//						print("JJJ: \(decryptedTestWords)")
//						print("LLL: \(decryptedTest)")
						/* We assume we have a valid text if more than 25% of the words match a real word */
						if matchingWordsCount > (decryptedTestWords.count*25)/100 {
							foundKey(k.map{ -$0 }, decryptedTest)
							return
						}
					}
				}
			}
		}
	}
	
}

func vigenereUnknownKey(_ str: String, _ dictionary: Set<String>) throws -> String {
	var message: String?
	let queue = OperationQueue()
	let dq = DispatchQueue(label: "reconciliation")
	let foundKeyHandler = {  (_ k: [CChar], _ m: String) in
		dq.sync{
			guard message == nil else {
				print("Found (at least) two matching messages!")
				return
			}
			message = m
			queue.cancelAllOperations()
		}
	}
	let nOp = 13
	let step = 26/nOp
	assert(26%nOp == 0)
	for i in 0..<nOp {
		queue.addOperation(FindVigenereOperation(string: str, minK1: i*step, maxK1: (i+1)*step, dictionary: dictionary, foundKeyHandler: foundKeyHandler))
	}
	queue.waitUntilAllOperationsAreFinished()
//	print(n)
	if let message = message {return message}
	throw NSError(domain: "riddlebot", code: 6, userInfo: nil)
}


let baseURL = URL(string: "https://api.noopschallenge.com/")!
let session = URLSession(configuration: URLSessionConfiguration.ephemeral)

do {
	let date = Date()
	print("Reading words list...")
	let wordsURL = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("words.txt")
	let wordsString = try String(contentsOf: wordsURL)
	let words = Set(wordsString.split(separator: "\n").map(String.init))
	print("Found \(words.count) words in \(-date.timeIntervalSinceNow) seconds")
	
	let loginRequest = LoginRequest(login: CommandLine.arguments[1])
	print("Logging in...")
	let loginResponse: LoginResponse = try session.synchronousFetch(url: URL(string: "/riddlebot/start", relativeTo: baseURL)!, httpMethod: "POST", httpBodyObject: loginRequest)

	var riddleURL = URL(string: loginResponse.riddlePath, relativeTo: baseURL)!
	while true {
		let answer: RiddleAnswer
		print()
		print("Fetching riddle at URL \(riddleURL.absoluteURL)")
		let riddle: Riddle = try session.synchronousFetch(url: riddleURL)
		print("Got riddle \(riddle)")
		switch riddle.riddleType {
		case .reverse(let text):            answer = RiddleAnswer(answer: String(text.reversed()))
		case .rot13(let text):              answer = RiddleAnswer(answer: rot13(text))
		case .caesar(let text, let key):    answer = RiddleAnswer(answer: caesar(text, -CChar(key)))
		case .vigenere(let text, let key):  answer = RiddleAnswer(answer: vigenere(text, key.map{ -CChar($0) }))
		case .caesarUnknownKey(let text):   try answer = RiddleAnswer(answer: caesarUnknownKey(text))
		case .vigenereUnknownKey(let text): try answer = RiddleAnswer(answer: vigenereUnknownKey(text, words))
		}
		print("Sending riddle response \(answer)")
		let response: RiddleAnswerResponse = try session.synchronousFetch(url: riddleURL, httpMethod: "POST", httpBodyObject: answer)
		guard let nextRiddlePath = response.nextRiddlePath else {
			throw NSError(domain: "riddlebot", code: 5, userInfo: nil)
		}
		riddleURL = URL(string: nextRiddlePath, relativeTo: baseURL)!
	}
} catch {
	print("Got error \(error)")
	exit(1)
}
