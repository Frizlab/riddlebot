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
		
		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let type = try container.decode(String.self, forKey: .riddleType)
			let text = try container.decode(String.self, forKey: .riddleText)
			switch type {
			case "reverse":  self = .reverse(text: text)
			case "rot13":    self = .rot13(text: text)
			case "caesar":   self = try .caesar(text: text, key: container.decode(Int.self, forKey: .riddleKey))
			case "vigenere": self = try .vigenere(text: text, key: container.decode([Int].self, forKey: .riddleKey))
			default: throw NSError(domain: "riddlebot", code: 2, userInfo: ["Unknown type": type, "Container": container])
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


let baseURL = URL(string: "https://api.noopschallenge.com/")!
let session = URLSession(configuration: URLSessionConfiguration.ephemeral)

do {
	let loginRequest = LoginRequest(login: "frizlab")
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
		}
		print("Sending riddle response \(answer)")
		let response: RiddleAnswerResponse = try session.synchronousFetch(url: riddleURL, httpMethod: "POST", httpBodyObject: answer)
		guard let nextRiddlePath = response.nextRiddlePath else {
			throw NSError(domain: "riddlebot", code: 3, userInfo: nil)
		}
		riddleURL = URL(string: nextRiddlePath, relativeTo: baseURL)!
	}
} catch {
	print("Got error \(error)")
	exit(1)
}
