#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>


typedef uint8_t bool;
#define true 1
#define false 0

/**
 * FAT12 Header Information:
 * 
 * Initializing the BPB (BIOS Parameter Block)
 * see https://wiki.osdev.org/FAT
*/
typedef struct 
{
    uint8_t BootJumpInstruction[3];
    uint8_t OemIdentifier[8];
    uint16_t BytesPerSector;
    uint8_t SectorsPerCluster;
    uint16_t ReservedSectors;
    uint8_t FatCount;
    uint16_t DirEntryCount;
    uint16_t TotalSectors;
    uint8_t MediaDescriptorType;
    uint16_t SectorsPerFat;
    uint16_t SectorsPerTrack;
    uint16_t Heads;
    uint32_t HiddenSectors;
    uint32_t LargeSectorCount;

    // extended boot record
    uint8_t DriveNumber;
    uint8_t _Reserved;
    uint8_t Signature;
    uint32_t VolumeId;          // serial number, value doesn't matter
    uint8_t VolumeLabel[11];    // 11 bytes, padded with spaces
    uint8_t SystemId[8];

    // ... we don't care about code ...

} __attribute__((packed)) BootSector; // we don't want any padding added to our struct, 
                                      // should match the FAT12 header exactly


typedef struct 
{
    uint8_t Name[11];
    uint8_t Attributes;
    uint8_t _Reserved;
    uint8_t CreatedTimeTenths;
    uint16_t CreatedTime;
    uint16_t CreatedDate;
    uint16_t AccessedDate;
    uint16_t FirstClusterHigh;
    uint16_t ModifiedTime;
    uint16_t ModifiedDate;
    uint16_t FirstClusterLow;
    uint32_t Size;
} __attribute__((packed)) DirectoryEntry;


// global reference to bootsector struct
BootSector global_BootSector;

// global reference to FAT struct
uint8_t* global_Fat = NULL;

// global reference to root directory struct
DirectoryEntry* global_RootDirectory = NULL;

uint32_t global_RootDirectoryEnd;


/**
 * Reads FAT12 boot sector heading from specified file
 * location into the global_BootSector struct
 * @param disk the disk file to read from
 * @return whether the read succeeded or failed
*/
bool readBootSector(FILE* disk)
{
    return fread(&global_BootSector, sizeof(global_BootSector), 1, disk) > 0;
}


/**
 * Reads the specified number of sectors to a designated location
 * @param disk the disk image to read from
 * @param lba the logical block address (lba), the index of the first sector to be read (lba is measured in sectors)
 * @param count the number of sectors to read
 * @param bufferOut the location to put the read sector data
 * @return whether the read succeeded or failed     
*/
bool readSectors(FILE* disk, uint32_t lba, uint32_t count, void* bufferOut)
{
    bool ok = true;

    // sets file position indicator (pointer) to correct starting address
    ok = ok && (fseek(disk, lba * global_BootSector.BytesPerSector, SEEK_SET) == 0);
    
    // reads count sectors into bufferOut starting at the previously set location (lba)
    // note that fread returns # items read
    ok = ok && (fread(bufferOut, global_BootSector.BytesPerSector, count, disk) == count);

    return ok;
}


/**
 * Reads the file allocation table into memory.
 * @param disk the disk file image to read from
 * @return whether the FAT was read successfully or not
*/
bool readFat(FILE* disk)
{   
    global_Fat = (uint8_t*) malloc(global_BootSector.SectorsPerFat * global_BootSector.BytesPerSector);
    return readSectors(disk, global_BootSector.ReservedSectors, global_BootSector.SectorsPerFat, global_Fat);
}


/**
 * Reads root directory from disk file image.
 * @param disk the disk file image to read from
 * @return Whether the read succeeded or failed
*/
bool readRootDirectory(FILE* disk) {
    // calculate starting lba for root directory (recall lba measured in sectors)
    uint32_t lba = global_BootSector.ReservedSectors + global_BootSector.FatCount * global_BootSector.SectorsPerFat;

    // size of root directory in bytes
    uint32_t size = global_BootSector.DirEntryCount * sizeof(DirectoryEntry);

    // number of sectors to read
    uint32_t sectors = size / global_BootSector.BytesPerSector;

    if (size % global_BootSector.BytesPerSector > 0) {
        sectors++; // round up
    }

    global_RootDirectoryEnd = lba + sectors;
    global_RootDirectory = (DirectoryEntry*) malloc(sectors * global_BootSector.BytesPerSector);
    return readSectors(disk, lba, sectors, global_RootDirectory);
}


/**
 * Finds file from root directory
 * @param name the name of the file to be found in the root directory
 * @return DirectoryEntry associated with the desired file
*/
DirectoryEntry* findFile(char* name) {
    for (uint32_t i = 0; i < global_BootSector.DirEntryCount; i++) {
        if (memcmp(name, global_RootDirectory[i].Name, 11) == 0) {
            return &global_RootDirectory[i];
        }
    }

    return NULL;
}


/**
 * Reads the contents of a specified file.
 * @param fileEntry a DirectoryEntry pointing to the fileEntry
 * @param disk the disk image to read from
 * @param outputBuffer the location to read the file contents into
 * @return Whether the file read was successful or not.
*/
bool readFile(DirectoryEntry* fileEntry, FILE* disk, uint8_t* outputBuffer) {

    bool ok = true;
    uint16_t currentCluster = fileEntry->FirstClusterLow;

    do {
        // read current cluster and update outputBuffer pointer
        uint32_t lba = global_RootDirectoryEnd + (currentCluster - 2) * global_BootSector.SectorsPerCluster;
        ok = ok && readSectors(disk, lba, global_BootSector.SectorsPerCluster, outputBuffer);
        outputBuffer += global_BootSector.SectorsPerCluster * global_BootSector.BytesPerSector;

        // determine next cluster
        // here, we are essentially making the conversion from 8-bit groupings in the FAT
        // to the 12-bit groupings used for the clusters, so 8 -> 12 is x1.5 
        uint32_t fatIndex = currentCluster * 3 / 2;

        // here, we will grab the two 8-bit groups from the FAT table that the
        // 12-bit cluster is split across, and use a bit mask to get the relevant bits
        if (currentCluster % 2 == 0) { // even cluster
            currentCluster = (*(uint16_t*)(global_Fat + fatIndex)) & 0x0FFF;
        } else { // odd cluster
            currentCluster = (*(uint16_t*)(global_Fat + fatIndex)) >> 4;
        }

    } while (ok && currentCluster < 0x0ff8); // cluster >= 0xff8 signifies end of chain

    return ok;

}

/**
 * Main method that takes 2 cli arguments
 * @param argc the number (count) of cli arguments
 * @param argv an array of cli arguments
 *             - fat disk image
 *             - file name of the file to be read
 * @return exit code
*/
int main(int argc, char** argv)
{

    if (argc < 3) {
        printf("Improper Command Usage\nCorrect Syntax: %s <disk image> <file name>\n", argv[0]);
        return -1;
    }

    FILE* disk = fopen(argv[1], "rb");
    if (!disk) {
        fprintf(stderr, "Cannot open disk image %s\n", argv[1]); // writes to stderr file
        return -1;
    }

    if (!readBootSector(disk)) {
        fprintf(stderr, "Could not read the boot sector!\n");
        return -2;
    }

    if (!readFat(disk)) {
        fprintf(stderr, "Could not read FAT!\n");
        free(global_Fat);
        return -3;
    }

    if (!readRootDirectory(disk)) {
        fprintf(stderr, "Could not read the Root Directory!\n");
        free(global_Fat);
        free(global_RootDirectory);
        return -4;
    }

    DirectoryEntry* fileEntry = findFile(argv[2]);
    if (!fileEntry) {
        fprintf(stderr, "Could not find File %s!\n", argv[2]);
        free(global_Fat);
        free(global_RootDirectory);
        return -5;
    }

    // we will store the file contents here
    // malloc extra sector so we don't overwrite anything or seg fault
    uint8_t* buffer = (uint8_t*) malloc(fileEntry->Size + global_BootSector.BytesPerSector);
    if (!readFile(fileEntry, disk, buffer)) {
        fprintf(stderr, "Could not read File %s!\n", argv[2]);
        free(global_Fat);
        free(global_RootDirectory);
        free(buffer);
        return -5;
    }

    // print file contents (hex if char not printable)
    for(size_t i = 0; i < fileEntry->Size; i++) {
        if (isprint(buffer[i])) fputc(buffer[i], stdout);
        else printf("<%02x>", buffer[i]);
    }

    printf("\n");

    free(buffer);
    free(global_Fat);
    free(global_RootDirectory);
    return 0;
}
