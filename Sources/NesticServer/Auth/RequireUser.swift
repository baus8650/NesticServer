//
//  RequireUser.swift
//  NesticServer
//
//  Created by Tim Bausch on 2/27/26.
//

import Vapor

extension Request {
    func requireUserID() throws -> UUID {
        // If you’re storing your JWT payload as SessionToken:
        let session = try self.auth.require(SessionToken.self)
        return session.userId
    }
}
