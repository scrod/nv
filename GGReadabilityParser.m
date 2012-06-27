/*
 Copyright (c) 2012 Curtis Hard - GeekyGoodness
*/

#import "GGReadabilityParser.h"

@interface GGReadabilityParser ( private )

- (NSXMLElement *)findBaseLevelContent:(NSXMLElement *)element;
- (NSInteger)scoreElement:(NSXMLElement *)element;

@end

@implementation GGReadabilityParser

@synthesize loadProgress;

- (void)dealloc
{
    [URL release], URL = nil;
    [URLResponse release], URLResponse = nil;
    [completionHandler release], completionHandler = nil;
    [errorHandler release], errorHandler = nil;
    [responseData release], responseData = nil;
    [URLConnection release], URLConnection = nil;
    [super dealloc];
}

- (id)initWithURL:(NSURL *)aURL
          options:(GGReadabilityParserOptions)parserOptions
completionHandler:(GGReadabilityParserCompletionHandler)cHandler
     errorHandler:(GGReadabilityParserErrorHandler)eHandler
{
    if( ( self = [super init] ) != nil )
    {
        URL = [aURL retain];
        options = parserOptions;
        completionHandler = [cHandler copy];
        errorHandler = [eHandler copy];
        responseData = [[NSMutableData alloc] init];
        [self setLoadProgress:.1];
    }
    return self;
}

- (void)cancel
{
    if( URLConnection != nil )
    {
        [URLConnection cancel];
    }
}

- (void)errorOut
{
    dispatch_async( dispatch_get_main_queue(), ^(void)
    {
        NSString * errorString = @"Readability was unable to find any suitable content.";
        NSError * error = [NSError errorWithDomain:@"com.geekygoodness.readability"
                                              code:1
                                          userInfo:[NSDictionary dictionaryWithObject:errorString
                                                                               forKey:NSLocalizedDescriptionKey]];
        errorHandler( error );
    });
}

- (void)render
{
    // set up the url connection
    URLConnection = [[NSURLConnection connectionWithRequest:[NSURLRequest requestWithURL:URL]
                                                   delegate:self] retain];
    [URLConnection start];
}

#pragma mark NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection
  didFailWithError:(NSError *)error
{
    errorHandler( error );
}

- (void)connection:(NSURLConnection *)connection
didReceiveResponse:(NSURLResponse *)response
{
    URLResponse = [response retain];
    dataLength = [response expectedContentLength];
}

- (void)connection:(NSURLConnection *)connection
    didReceiveData:(NSData *)data
{
    [responseData appendData:data];
    
    // now set up the percentage
    float prog = ( fabs( (float)[responseData length] / (float)dataLength ) / 100000 ) + 0.1;
    [self setLoadProgress:( prog >= 8.5 ? 8.5 : prog )];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    // async please
    dispatch_async( dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0 ), ^(void)
    {
        NSString * str = nil;
        
        // encodings to try
        NSInteger encodings[4] = {
            NSUTF8StringEncoding,
            NSMacOSRomanStringEncoding,
            NSASCIIStringEncoding,
            NSUTF16StringEncoding
        };
        
				NSInteger i = 0;
        // some sites might not be UTF8, so try until nil
        for( i; i < sizeof( encodings ) / sizeof( NSInteger ); i++ )
        {
            if( ( str = [[[NSString alloc] initWithData:responseData
                                               encoding:encodings[i]] autorelease] ) != nil )
            {
                break;
            }
        }
        
        // if cant convert data to a string, just die
        if( str == nil )
        {
            [self errorOut];
            return;
        }
        
        // render
        [self renderWithString:str];
    });
}

- (void)renderWithString:(NSString *)string
{
    
    // if the main thread, send to an async thread instead
    if( [NSThread currentThread] == [NSThread mainThread] )
    {
        dispatch_async( dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0 ), ^(void){
            [self renderWithString:string];
        });
        return;
    }
    
    NSError * error = nil; // we dont actually pay attention to this
    
    NSInteger types[2] = {
        NSXMLDocumentTidyHTML,
        NSXMLDocumentTidyXML
    };
    
    NSXMLDocument * XML = nil;
    NSXMLElement * theEl = nil;
    
    // different types, html, xml
    BOOL OKToGo = NO;
		NSInteger i = 0;
    for(i; i < sizeof( types ) / sizeof( NSInteger ); i++ )
    {
        XML = [[[NSXMLDocument alloc] initWithXMLString:string
                                                options:types[i]
                                                  error:&error] autorelease];
        
        // find the body tag
        NSXMLElement * el = [[XML nodesForXPath:@"//body"
                                          error:&error] lastObject];
        
        // is there a child count?
        if( [el childCount] != 0 )
        {
            theEl = el;
            OKToGo = YES;
            break;
        }
    }
    
    // error out if no xml
    if( ! OKToGo )
    {
        [self errorOut];
        return;
    }
    
    // let the fun begin
    NSXMLElement * element = [self findBaseLevelContent:theEl];
    
    if( ! element )
    {
        // we tried :-(
        [self errorOut];
        return;
    }

    // now we have the base element to work with, lets remove all div's that dont have a parent of a p
    
    NSMutableArray * elementsToRemove = [[[NSMutableArray alloc] init] autorelease];
    
    // remove divs
    if( options & GGReadabilityParserOptionRemoveDivs )
    {
        [elementsToRemove addObject:@"div"];
    }
    
    // remove embeds
    if( options & GGReadabilityParserOptionRemoveEmbeds )
    {
        [elementsToRemove addObject:@"embed"];
        [elementsToRemove addObject:@"object"];
    }
    
    // remove iframes
    if( options & GGReadabilityParserOptionRemoveIFrames )
    {
        [elementsToRemove addObject:@"iframe"];
    }
    
    // remove images
    if( options & GGReadabilityParserOptionRemoveImages )
    {
        [elementsToRemove addObject:@"img"];
    }
    
    // remove headers
    if( options & GGReadabilityParserOptionRemoveHeader )
    {
        [elementsToRemove addObject:@"h1"];
    }
    
    // remove more headers
    if( options & GGReadabilityParserOptionRemoveHeaders )
    {
				NSInteger i;
        for( i = 2; i <= 6; i++ )
        {
            [elementsToRemove addObject:[NSString stringWithFormat:@"h%ld",i]];
        }
    }
    
    // remove any tags specified
    for( NSString * tagToRemove in elementsToRemove )
    {
        NSArray * removeElements = [element nodesForXPath:[NSString stringWithFormat:@"//%@",tagToRemove]
                                                    error:&error];
        for( NSXMLElement * removeEl in removeElements )
        {
            [(NSXMLElement *)[removeEl parent] removeChildAtIndex:[removeEl index]];
        }
    }
    
    // remove any styles
    if( options & GGReadabilityParserOptionClearStyles )
    {
        NSArray * cleanArray = [element nodesForXPath:@"//*[@style]"
                                                error:&error];
        for( NSXMLElement * cleanElement in cleanArray )
        {
            [cleanElement removeAttributeForName:@"style"];
        }
    }
    
    // clear link lists
    if( options & GGReadabilityParserOptionClearLinkLists )
    {
        NSArray * lookFor = [NSArray arrayWithObjects:@"similar",@"bookmark",@"links",@"social",@"nav",@"comments",@"comment",@"date",@"author",@"time",@"cat",@"related", nil];
        NSArray * allElements = [element nodesForXPath:@"//*"
                                                 error:&error];
        for( NSXMLElement * theElement in allElements )
        {
            // grab the ids
            NSArray * idNames = [[[theElement attributeForName:@"id"] stringValue] componentsSeparatedByString:@" "];
            
            // and class names
            NSArray * classNames = [[[theElement attributeForName:@"class"] stringValue] componentsSeparatedByString:@" "];
            
            BOOL killElement = NO;
            for( NSString * idName in idNames )
            {
                for( NSString * matchAgainst in lookFor )
                {
                    if( [idName rangeOfString:matchAgainst].length != 0 )
                    {
                        killElement = YES;
                        break;
                    }
                }
                if( killElement )
                {
                    break;
                }
            }
            
            if( killElement )
            {
                [(NSXMLElement *)[theElement parent] removeChildAtIndex:[theElement index]];
                continue;
            }
            
            // now class names
            for( NSString * className in classNames )
            {
                for( NSString * matchAgainst in lookFor )
                {
                    if( [className rangeOfString:matchAgainst].length != 0 )
                    {
                        killElement = YES;
                        break;
                    }
                }
                if( killElement )
                {
                    break;
                }
            }
            
            // if kill element, remove it!
            if( killElement )
            {
                [(NSXMLElement *)[theElement parent] removeChildAtIndex:[theElement index]];
            }
            
        }
    }
    
    // do we need to fix the links or the images
    [elementsToRemove removeAllObjects];
    
    // img tags
    if( options & GGReadabilityParserOptionFixImages )
    {
        [elementsToRemove addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"img",@"tagName",@"src",@"attributeName",nil]];
    }
    
    // a tags
    if( options & GGReadabilityParserOptionFixLinks )
    {
        [elementsToRemove addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"a",@"tagName",@"href",@"attributeName",nil]];
    }
    
    // ignore the name, just easy to reuse
    NSString * baseURL = [NSString stringWithFormat:@"%@://%@",[[URLResponse URL] scheme],[[URLResponse URL] host]];
    for( NSDictionary * dict in elementsToRemove )
    {
        // grab the elements
        NSArray * els = [element nodesForXPath:[NSString stringWithFormat:@"//%@",[dict objectForKey:@"tagName"]]
                                         error:&error];
        for( NSXMLElement * fixEl in els )
        {
            NSXMLNode * attribute = [fixEl attributeForName:[dict objectForKey:@"attributeName"]];
            if( [[attribute stringValue] length] != 0 && 
               [[[attribute stringValue] substringToIndex:1] isEqualToString:@"/"] )
            {
                // needs fixing
                NSString * newAttributeString = [NSString stringWithFormat:@"%@%@",baseURL,[attribute stringValue]];
                [attribute setStringValue:newAttributeString];
            }
        }
    }
    
    // were done!
    
    NSData * data = [[element XMLString] dataUsingEncoding:NSUTF8StringEncoding
                                      allowLossyConversion:YES];
    
    NSString * returnContents = [[[NSString alloc] initWithData:data
                                                       encoding:NSUTF8StringEncoding] autorelease];
    
    // tell our handler :-)
    dispatch_async( dispatch_get_main_queue(), ^(void)
    {
        [self setLoadProgress:1.0];
        if( [returnContents length] == 0 )
        {
            [self errorOut];
            return;
        }
        completionHandler( returnContents );
    });   
}

- (NSXMLElement *)findBaseLevelContent:(NSXMLElement *)element
{
    NSError * error = nil; // again, we dont actually care
    // generally speaking, the content lies within ptags - we hope
    
    // clean up the element
    NSArray * toRemove = [NSArray arrayWithObjects:@"noscript",@"script",@"form", nil];
    for( NSString * removeTag in toRemove )
    {
        // find them all
        NSArray * removeArray = [element nodesForXPath:[NSString stringWithFormat:@"//%@",removeTag]
                                                 error:&error];
        for( NSXMLElement * removeElement in removeArray )
        {
            [(NSXMLElement *)[removeElement parent] removeChildAtIndex:[removeElement index]];
        }
    }
    
    // basic instant wins
    NSArray * instantWins = [NSArray arrayWithObjects:@"article-body", nil];
    
    NSInteger pCount = 0;
    NSXMLElement * foundElement = nil;
    
    for( NSString * instantWinName in instantWins )
    {
        NSArray * nodes = [element nodesForXPath:[NSString stringWithFormat:@"//*[contains(@class,'%@') or contains(@id,'%@')]", instantWinName, instantWinName]
                                           error:&error];
        if( [nodes count] != 0 )
        {
            for( NSXMLElement * winElement in nodes )
            {
                NSInteger count = [[winElement nodesForXPath:@"//p"
                                                       error:&error] count];
                if( count > pCount )
                {
                    pCount = count;
                    foundElement = winElement;
                }
            }
        }
    }
    
    // we found a winning match!
    if( foundElement != nil )
    {
        return foundElement;
    }
    
    NSArray * tags = [element nodesForXPath:@"//p"
                                      error:&error];
    
    NSInteger currentCount = 0;
    NSXMLElement * tagParent = nil;
    for( NSXMLElement * tag in tags )
    {
        NSXMLElement * parent = (NSXMLElement *)[tag parent];
        
        // count how many p tags are inside the parent
        NSInteger parentTagsCount = [[parent nodesForXPath:@"p"
                                                     error:&error] count];
        if( parentTagsCount > currentCount )
        {
            currentCount = parentTagsCount;
            tagParent = parent;
        }
    }
    
    // old school br tags ( people still do this? :-( )
    BOOL usingBR = NO;
    if( tagParent == nil )
    {
        // try old school br tags
        currentCount = 0;
        usingBR = YES;
        tags = [element nodesForXPath:@"//br"
                                error:&error];
        for( NSXMLElement * tag in tags )
        {
            NSXMLElement * parent = (NSXMLElement *)[tag parent];
            
            // count how many br tags there are
            NSInteger parentTagsCount = [[parent nodesForXPath:@"br"
                                                         error:&error] count];
            parentTagsCount += [self scoreElement:parent];
            if( parentTagsCount > currentCount )
            {
                currentCount = parentTagsCount;
                tagParent = parent;
            }
        }
    }
    
    // current br count
    if( usingBR && tagParent )
    {
        NSInteger textChildren = 0;
        NSInteger brs = 0;
        for( NSXMLElement * el in [tagParent children] )
        {
            if( [el kind] == NSXMLTextKind )
            {
                textChildren++;
            } else if ( [[[el name] lowercaseString] isEqualToString:@"br"] ) {
                brs++;
            }
        }
        
        // whats the ratio?
        if( textChildren < ( brs / 2 ) )
        {
            tagParent = nil;
        } else {
            // remove any br tags directly next to each other
            NSArray * brs = [tagParent nodesForXPath:@"//br[preceding-sibling::br[1]]"
                                               error:&error];
            for( NSXMLElement * br in brs )
            {
                [(NSXMLElement *)[br parent] removeChildAtIndex:[br index]];
            }
        }
        
    }
    // if nothing is found, lets try something else...
    if( tagParent == nil )
    {
        
        // now were going to find and find the content, because either they dont use ptags or its just horrible markup
    
        NSArray * elements = [element nodesForXPath:@"//*"
                                              error:&error];
        
        NSMutableDictionary * scoreDict = [[[NSMutableDictionary alloc] init] autorelease];
    
        NSXMLElement * currentElement = nil;
    
        // grab everything that has it within class or id
        for( NSXMLElement * el in elements )
        {  
            // grab its hash
            NSInteger score = [scoreDict objectForKey:el] ? [[scoreDict objectForKey:el] integerValue] : 0;
            score += [self scoreElement:el];
            
            // store it within a dict
            [scoreDict setObject:[NSNumber numberWithInteger:score]
                          forKey:el];                
        }        
       
        // set the parent tag
        tagParent = currentElement;
        
    }
    
    return tagParent;
}

- (NSInteger)scoreElement:(NSXMLElement *)element
{
    // these are key words that will probably be inside the class or id of the element that houses the content
    NSArray * scores = [NSArray arrayWithObjects:@"post",@"entry",@"content",@"text",@"article",@"story",@"blog", nil];
    NSInteger score = 0;
    for( NSString * possitiveWord in scores )
    {
        score += [[[element name] lowercaseString] isEqualToString:possitiveWord] ? 150 : 0;
        
        // grab the class names and id names
        NSArray * classNames = [[[element attributeForName:@"class"] stringValue] componentsSeparatedByString:@" "];
        NSArray * idNames = [[[element attributeForName:@"id"] stringValue] componentsSeparatedByString:@" "];
        
        // match against the possitive class
        for( NSString * className in classNames )
        {
            score += [className rangeOfString:possitiveWord].length != 0 ? 20 : 0;
        }
        
        // match against the possitive id
        for( NSString * idName in idNames )
        {
            score += [idName rangeOfString:possitiveWord].length != 0 ? 30 : 0;
        }
    }
    return score;
}

@end
