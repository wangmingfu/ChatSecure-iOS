//
//  OTRXMPPRoomYapStorage.m
//  ChatSecure
//
//  Created by David Chiles on 10/7/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

#import "OTRXMPPRoomYapStorage.h"
#import <ChatSecureCore/OTRDatabaseManager.h>
#import <ChatSecureCore/ChatSecureCore-Swift.h>
#import <YapDatabase/YapDatabaseRelationship.h>
#import <ChatSecureCore/OTRAccount.h>
#import "NSXMLElement+XEP_0203.h"

@interface OTRXMPPRoomYapStorage ()

@property (nonatomic) dispatch_queue_t parentQueue;

@end

@implementation OTRXMPPRoomYapStorage

- (instancetype)initWithDatabaseConnection:(YapDatabaseConnection *)databaseConnection
{
    if (self = [self init]){
        self.databaseConnection = databaseConnection;
    }
    return self;
}

- (OTRXMPPRoomOccupant *)roomOccupantForJID:(NSString *)jid roomJID:(NSString *)roomJID accountId:(NSString *)accountId inTransaction:(YapDatabaseReadTransaction *)transaction
{
    __block OTRXMPPRoomOccupant *occupant = nil;
        
    OTRXMPPRoom *databaseRoom = [self fetchRoomWithXMPPRoomJID:roomJID accountId:accountId inTransaction:transaction];
    //Enumerate of room eges to occupants
    [[transaction ext:OTRYapDatabaseRelationshipName] enumerateEdgesWithName:[OTRXMPPRoomOccupant roomEdgeName] destinationKey:databaseRoom.uniqueId collection:[OTRXMPPRoom collection] usingBlock:^(YapDatabaseRelationshipEdge *edge, BOOL *stop) {
        
        OTRXMPPRoomOccupant *tempOccupant = [transaction objectForKey:edge.sourceKey inCollection:edge.sourceCollection];
        if([tempOccupant.jid isEqualToString:jid]) {
            
            occupant = tempOccupant;
            *stop = YES;
        }
    }];
    
    if(!occupant) {
        occupant = [[OTRXMPPRoomOccupant alloc] init];
        occupant.jid = jid;
        occupant.roomUniqueId = [OTRXMPPRoom createUniqueId:accountId jid:roomJID];
    }
    return occupant;
}

- (OTRXMPPRoom *)fetchRoomWithXMPPRoomJID:(NSString *)roomJID accountId:(NSString *)accountId inTransaction:(YapDatabaseReadTransaction *)transaction {
    return [OTRXMPPRoom fetchObjectWithUniqueID:[OTRXMPPRoom createUniqueId:accountId jid:roomJID] transaction:transaction];
}

- (void)insertMessage:(XMPPMessage *)message intoRoom:(XMPPRoom *)room outgoing:(BOOL)outgoing
{
    NSString *accountId = room.xmppStream.tag;
    NSString *roomJID = room.roomJID.bare;
    XMPPJID *fromJID = [message from];
    [self.databaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        OTRXMPPRoomMessage *databaseMessage = [[OTRXMPPRoomMessage alloc] init];
        databaseMessage.text = [message body];
        databaseMessage.date = [message delayedDeliveryDate];
        if (!databaseMessage.date) {
            databaseMessage.date = [NSDate date];
        }
        databaseMessage.senderJID = [fromJID full];
        OTRXMPPRoom *databaseRoom = [self fetchRoomWithXMPPRoomJID:roomJID accountId:accountId inTransaction:transaction];
        databaseMessage.roomJID = databaseRoom.jid;
        databaseMessage.incoming = !outgoing;
        databaseMessage.roomUniqueId = databaseRoom.uniqueId;
        
        [databaseMessage saveWithTransaction:transaction];
    }];
}

//MARK: XMPPRoomStorage

- (BOOL)configureWithParent:(XMPPRoom *)aParent queue:(dispatch_queue_t)queue
{
    self.parentQueue = queue;
    return YES;
}

/**
 * Updates and returns the occupant for the given presence element.
 * If the presence type is "available", and the occupant doesn't already exist, then one should be created.
 **/
- (void)handlePresence:(XMPPPresence *)presence room:(XMPPRoom *)room {
    NSString *accountId = room.xmppStream.tag;
    XMPPJID *presenceJID = [presence from];
    NSArray *children = [presence children];
    __block XMPPJID *buddyJID = nil;
    [children enumerateObjectsUsingBlock:^(NSXMLElement *element, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([[element xmlns] containsString:XMPPMUCNamespace]) {
            NSArray *items = [element children];
            [items enumerateObjectsUsingBlock:^(NSXMLElement *item, NSUInteger idx, BOOL * _Nonnull stop) {
                NSString *jid = [item attributeStringValueForName:@"jid"];
                if ([jid length]) {
                    buddyJID = [XMPPJID jidWithString:jid];
                    *stop = YES;
                }
            }];
            *stop = YES;
        }
    }];
    
    [self.databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {

        
        OTRXMPPRoomOccupant *occupant = [self roomOccupantForJID:[presenceJID full] roomJID:room.roomJID.bare accountId:accountId inTransaction:transaction];
        if ([[presence type] isEqualToString:@"unavailable"]) {
            occupant.available = NO;
        } else {
            occupant.available = YES;
        }
        
        if (buddyJID) {
            occupant.realJID = buddyJID.bare;
        }
        
        occupant.roomName = [presenceJID resource];
        
        
    
        [occupant saveWithTransaction:transaction];
    }];
}

/**
 * Stores or otherwise handles the given message element.
 **/
- (void)handleIncomingMessage:(XMPPMessage *)message room:(XMPPRoom *)room {
    XMPPJID *myRoomJID = room.myRoomJID;
    XMPPJID *messageJID = [message from];
    
    if ([myRoomJID isEqualToJID:messageJID])
    {
        if (![message wasDelayed])
        {
            // Ignore - we already stored message in handleOutgoingMessage:room:
            return;
        }
    }
    
    //May need to check if the message is unique. Unsure if this is a real problem. Look at XMPPRoomCoreDataStorage.m existsMessage:
    [self insertMessage:message intoRoom:room outgoing:NO];
}
- (void)handleOutgoingMessage:(XMPPMessage *)message room:(XMPPRoom *)room {
    
}

/**
 * Handles leaving the room, which generally means clearing the list of occupants.
 **/
- (void)handleDidLeaveRoom:(XMPPRoom *)room {
    NSString *roomJID = room.roomJID.bare;
    NSString *accountId = room.xmppStream.tag;
    [self.databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        OTRXMPPRoom *databaseRoom = [self fetchRoomWithXMPPRoomJID:roomJID accountId:accountId inTransaction:transaction];
        databaseRoom.joined = NO;
        [databaseRoom saveWithTransaction:transaction];
    }];
}

- (void)handleDidJoinRoom:(XMPPRoom *)room withNickname:(NSString *)nickname {
    NSString *roomJID = room.roomJID.bare;
    NSString *accountId = room.xmppStream.tag;
    [self.databaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        OTRXMPPRoom *databaseRoom = [self fetchRoomWithXMPPRoomJID:roomJID accountId:accountId inTransaction:transaction];
        
        databaseRoom.joined = YES;
        [databaseRoom saveWithTransaction:transaction];
    }];
}



@end