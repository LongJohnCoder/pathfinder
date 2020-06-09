#version 430

// pathfinder/shaders/propagate.cs.glsl
//
// Copyright © 2020 The Pathfinder Project Developers.
//
// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

// Sum up backdrops to propagate fills across tiles.

#extension GL_GOOGLE_include_directive : enable

precision highp float;

#ifdef GL_ES
precision highp sampler2D;
#endif

layout(local_size_x = 64) in;

#define TILE_FIELD_NEXT_TILE_ID             0
#define TILE_FIELD_FIRST_FILL_ID            1
#define TILE_FIELD_BACKDROP_ALPHA_TILE_ID   2
#define TILE_FIELD_CONTROL                  3

uniform ivec2 uFramebufferTileSize;
uniform int uColumnCount;

layout(std430, binding = 0) buffer bDrawMetadata {
    // [0]: tile rect
    // [1].x: tile offset
    // [1].y: path ID
    // [1].z: Z write enabled?
    // [1].w: clip path ID, or ~0
    // [2].x: backdrop column offset
    restrict readonly uvec4 iDrawMetadata[];
};

layout(std430, binding = 1) buffer bClipMetadata {
    // [0]: tile rect
    // [1].x: tile offset
    // [1].y: unused
    // [1].z: unused
    // [1].w: unused
    restrict readonly uvec4 iClipMetadata[];
};

layout(std430, binding = 2) buffer bBackdrops {
    // [0]: backdrop
    // [1]: tile X offset
    // [2]: path ID
    restrict readonly int iBackdrops[];
};

layout(std430, binding = 3) buffer bDrawTiles {
    // [0]: next tile ID
    // [1]: first fill ID
    // [2]: backdrop delta upper 8 bits, alpha tile ID lower 24
    // [3]: color/ctrl/backdrop word
    restrict uint iDrawTiles[];
};

layout(std430, binding = 4) buffer bClipTiles {
    // [0]: next tile ID
    // [1]: first fill ID
    // [2]: backdrop delta upper 8 bits, alpha tile ID lower 24
    // [3]: color/ctrl/backdrop word
    restrict uint iClipTiles[];
};

layout(std430, binding = 5) buffer bClipVertexBuffer {
    restrict ivec4 iClipVertexBuffer[];
};

layout(std430, binding = 6) buffer bZBuffer {
    restrict int iZBuffer[];
};

layout(std430, binding = 7) buffer bFirstTileMap {
    restrict int iFirstTileMap[];
};

layout(std430, binding = 8) buffer bIndirectDrawParams {
    // [0]: vertexCount (6)
    // [1]: instanceCount (of fills)
    // [2]: vertexStart (0)
    // [3]: baseInstance (0)
    // [4]: alpha tile count
    restrict uint iIndirectDrawParams[];
};

layout(std430, binding = 9) buffer bAlphaTiles {
    // [0]: alpha tile index
    // [1]: clip tile index
    restrict uint iAlphaTiles[];
};

uint calculateTileIndex(uint bufferOffset, uvec4 tileRect, uvec2 tileCoord) {
    return bufferOffset + tileCoord.y * (tileRect.z - tileRect.x) + tileCoord.x;
}

void main() {
    uint columnIndex = gl_GlobalInvocationID.x;
    if (int(columnIndex) >= uColumnCount)
        return;

    int currentBackdrop = iBackdrops[columnIndex * 3 + 0];
    int tileX = iBackdrops[columnIndex * 3 + 1];
    uint drawPathIndex = uint(iBackdrops[columnIndex * 3 + 2]);

    uvec4 drawTileRect = iDrawMetadata[drawPathIndex * 3 + 0];
    uvec4 drawOffsets = iDrawMetadata[drawPathIndex * 3 + 1];
    uvec2 drawTileSize = drawTileRect.zw - drawTileRect.xy;
    uint drawTileBufferOffset = drawOffsets.x;
    bool zWrite = drawOffsets.z != 0;

    int clipPathIndex = int(drawOffsets.w);
    uvec4 clipTileRect = uvec4(0u), clipOffsets = uvec4(0u);
    if (clipPathIndex >= 0) {
        clipTileRect = iClipMetadata[clipPathIndex * 2 + 0];
        clipOffsets = iClipMetadata[clipPathIndex * 2 + 1];
    }
    uint clipTileBufferOffset = clipOffsets.x, clipBackdropOffset = clipOffsets.y;

    for (uint tileY = 0; tileY < drawTileSize.y; tileY++) {
        uvec2 drawTileCoord = uvec2(tileX, tileY);
        uint drawTileIndex = calculateTileIndex(drawTileBufferOffset, drawTileRect, drawTileCoord);

        int drawAlphaTileIndex = -1;
        int drawFirstFillIndex = int(iDrawTiles[drawTileIndex * 4 + TILE_FIELD_FIRST_FILL_ID]);
        int drawBackdropDelta =
            int(iDrawTiles[drawTileIndex * 4 + TILE_FIELD_BACKDROP_ALPHA_TILE_ID]) >> 24;
        uint drawTileWord = iDrawTiles[drawTileIndex * 4 + TILE_FIELD_CONTROL] & 0x00ffffff;

        int drawTileBackdrop = currentBackdrop;

        // Allocate an alpha tile if necessary.
        // TODO(pcwalton): Don't do this if we're just going to overwrite it later.
        if (drawFirstFillIndex >= 0)
            drawAlphaTileIndex = int(atomicAdd(iIndirectDrawParams[4], 1));

        // Handle clip if necessary.
        if (clipPathIndex >= 0) {
            uvec2 tileCoord = drawTileCoord + drawTileRect.xy;
            ivec4 clipTileData = ivec4(-1, 0, -1, 0);
            if (all(bvec4(greaterThanEqual(tileCoord, clipTileRect.xy),
                          lessThan        (tileCoord, clipTileRect.zw)))) {
                uvec2 clipTileCoord = tileCoord - clipTileRect.xy;
                uint clipTileIndex = calculateTileIndex(clipTileBufferOffset,
                                                        clipTileRect,
                                                        clipTileCoord);

                int clipAlphaTileIndex = int(iClipTiles[clipTileIndex * 4 + 1]);
                uint clipTileWord = iClipTiles[clipTileIndex * 4 + 3];
                int clipTileBackdrop = int(clipTileWord) >> 24;

                if (clipAlphaTileIndex >= 0 && drawAlphaTileIndex >= 0) {
                    // Hard case: We have an alpha tile and a clip tile with masks. Add a job to
                    // combine the two masks. Because the mask combining step applies the
                    // backdrops, zero out the backdrop in the draw tile itself so that we don't
                    // double-count it.
                    clipTileData = ivec4(drawAlphaTileIndex,
                                         drawTileBackdrop,
                                         clipAlphaTileIndex,
                                         clipTileBackdrop);
                    drawTileBackdrop = 0;
                } else if (clipAlphaTileIndex >= 0 &&
                           drawAlphaTileIndex < 0 &&
                           drawTileBackdrop != 0) {
                    // This is a solid draw tile, but there's a clip applied. Replace it with an
                    // alpha tile pointing directly to the clip mask.
                    drawAlphaTileIndex = clipAlphaTileIndex;
                    drawTileBackdrop = clipTileBackdrop;
                } else if (clipAlphaTileIndex < 0 && clipTileBackdrop == 0) {
                    // This is a blank clip tile. Cull the draw tile entirely.
                    drawAlphaTileIndex = -1;
                    drawTileBackdrop = 0;
                }
            } else {
                // This draw tile is outside the clip path bounding rect. Cull the draw tile.
                drawAlphaTileIndex = -1;
                drawTileBackdrop = 0;
            }

            iClipVertexBuffer[drawTileIndex] = clipTileData;
        }

        if (drawAlphaTileIndex >= 0) {
            iAlphaTiles[drawAlphaTileIndex * 2 + 0] = drawTileIndex;
            iAlphaTiles[drawAlphaTileIndex * 2 + 1] = -1;
        }

        iDrawTiles[drawTileIndex * 4 + TILE_FIELD_BACKDROP_ALPHA_TILE_ID] =
            (uint(drawAlphaTileIndex) & 0x00ffffffu) | (uint(drawBackdropDelta) << 24);
        iDrawTiles[drawTileIndex * 4 + TILE_FIELD_CONTROL] =
            drawTileWord | (uint(drawTileBackdrop) << 24);

        // Write to Z-buffer if necessary.
        ivec2 tileCoord = ivec2(tileX, tileY) + ivec2(drawTileRect.xy);
        int tileMapIndex = tileCoord.y * uFramebufferTileSize.x + tileCoord.x;
        if (zWrite && drawTileBackdrop != 0 && drawAlphaTileIndex < 0)
            atomicMax(iZBuffer[tileMapIndex], int(drawPathIndex));

        // Stitch into the linked list if necessary.
        if (drawTileBackdrop != 0 || drawAlphaTileIndex >= 0) {
            int nextTileIndex = atomicExchange(iFirstTileMap[tileMapIndex], int(drawTileIndex));
            iDrawTiles[drawTileIndex * 4 + TILE_FIELD_NEXT_TILE_ID] = nextTileIndex;
        }

        currentBackdrop += drawBackdropDelta;
    }
}
