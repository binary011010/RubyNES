require "constants"
require "ppu_helper"

# Note, Debugger must be available as a global constant 'DEBUG'

class PPU
  attr_accessor :mmc
  attr_accessor :name_table_mirroring
  attr_accessor :control_reg_1, :control_reg_2, :status, :sprite_mem_addr
  attr_accessor :vertical_scroll_reg, :horizontal_scroll_reg, :ppu_mem_addr
  attr_accessor :screen_buffer
  attr_accessor :scanline, :elapsed_cycles
  attr_accessor :frame_complete
  
  include Constants
  include PPUHelper
  
  public
  def initialize(mmc)
    super()
    
    @mmc = mmc
    
    @control_reg_1 = 0
    @control_reg_2 = 0x18
    @status = 0 # @TODO: Correct init value? 
    @sprite_mem_addr = 0
    @name_table_mirroring = 0
    @vertical_scroll_reg = 0 #@TODO: Correct init value?
    @horizontal_scroll_reg = 0 #@TODO: Correct init value?
    @ppu_mem_addr = 0
    
    # Buffer of 241 scanlines (1 is a dummy with nothing drawn), 256 pixels per line (palette entries)
    @screen_buffer = Array.new(241, nil)
    @screen_buffer.each_index {|index|
      @screen_buffer[index] = Array.new(256, 0)
    }
    
    @elapsed_cycles = 0
    @scanline = 0
    
    @log_ppu_state = false
    
    @background_color = 0x0F # Palette Black
    
    # Frame complete flag must be reset from outside this class
    @frame_complete = false
    
    # Add debug commands
    DEBUG.debug_addcommand "enableppulogging", Proc.new {|param| @log_ppu_state = true}
    DEBUG.debug_addcommand "disableppulogging", Proc.new {|param| @log_ppu_state = false}
  end
  
  def pre_frame
    # Fill the screen with the background color
    #fill_screen_with_background_color

    # Clear Sprite #0 hit flag
    set_hit_flag(false)
  end
  
  def post_frame
    # Raise the VBlank flag, NMI will be triggered
    set_vblank_flag(true)
    
    #DEBUG.debug_print "VBLANK.\n"
    DEBUG.debug_log "VBLANK.\n" if @log_ppu_state

    @mmc.cpu.nmi if vblank_enable_flag_set? # Force CPU Non-maskable Interrupt
    
    @frame_complete = true
  end
  
  def execute(cycles)
    vblank_hit = false
    pre_vblank_cycles = 0
    
    # Execute so many cycles
    (1..cycles).each { |cycle|
      @scanline = (cycle + @elapsed_cycles) / SCANLINE_CYCLES  # What scanline are we on?
      scanline_cycle = (cycle + @elapsed_cycles) % SCANLINE_CYCLES  # What cycle within the scanline is this?
      tile_pixel = scanline_cycle % 8
    
      if @scanline < 20
        # Do nothing for first 20 scanlines
      elsif @scanline == 20
        # Scanline 20 has some unique properties, first of all pull down the VINT flag
        set_vblank_flag(false) if (vblank_flag_set?)

        if (tile_pixel == 0)
          # Read Name Table byte, Attribute Table byte and 2 Pattern Table bytes
          true_scanline = @scanline - 20
          @tile_index = get_tile_index(true_scanline, scanline_cycle)
          @name_table_address = get_name_table_address
          @pattern_table_index = @mmc.read_ppu_mem(@name_table_address + @tile_index) # From Name Table
          @pattern_table_byte1 = @mmc.read_ppu_mem(get_screen_pattern_table_address + get_pattern_table_byte1_index(@pattern_table_index, true_scanline))
          @pattern_table_byte2 = @mmc.read_ppu_mem(get_screen_pattern_table_address + get_pattern_table_byte2_index(@pattern_table_index, true_scanline))
          @attribute_table_index = get_attribute_table_index(@tile_index)
          @attribute_table_byte = @mmc.read_ppu_mem(@name_table_address + NAME_TABLE_SIZE + @attribute_table_index)
        end
        
        # Nothing rendered on this scanline
        
      elsif @scanline < 261
        # Ordinary rendering for scanline 21 thru 260
        true_scanline = @scanline - 20
        if (tile_pixel == 0)
          # Read Name Table byte, Attribute Table byte and 2 Pattern Table bytes
          if screen_enable_flag_set?
            @tile_index = get_tile_index(true_scanline, scanline_cycle)
            @name_table_address = get_name_table_address
            @pattern_table_index = @mmc.read_ppu_mem(@name_table_address + @tile_index) # From Name Table
            @pattern_table_byte1 = @mmc.read_ppu_mem(get_screen_pattern_table_address + get_pattern_table_byte1_index(@pattern_table_index, true_scanline))
            @pattern_table_byte2 = @mmc.read_ppu_mem(get_screen_pattern_table_address + get_pattern_table_byte2_index(@pattern_table_index, true_scanline))
            @attribute_table_index = get_attribute_table_index(@tile_index)
            @attribute_table_byte = @mmc.read_ppu_mem(@name_table_address + NAME_TABLE_SIZE + @attribute_table_index)
            @attribute_table_square = get_attribute_table_square(@tile_index)
          end

          # Get sprites for this tile
          if sprite_enable_flag_set?
            @applicable_sprites = get_applicable_sprites(true_scanline, scanline_cycle, sprite_size_flag_set?)
          else
            @applicable_sprites = nil
          end

        end

        # Draw screen
        palette_index = 0
        if screen_enable_flag_set?
          palette_index |= ((@pattern_table_byte1 & PATTERN_TABLE_BIT_MASK[tile_pixel]) >> PATTERN_TABLE_BYTE1_BIT_SHIFT[tile_pixel])
          palette_index |= ((@pattern_table_byte2 & PATTERN_TABLE_BIT_MASK[tile_pixel]) >> PATTERN_TABLE_BYTE2_BIT_SHIFT[tile_pixel])
          palette_index |= ((@attribute_table_byte & ATTRIBUTE_TABLE_BIT_MASK[@attribute_table_square]) >> ATTRIBUTE_TABLE_BIT_SHIFT[@attribute_table_square])

          if (scanline_cycle < 8)
            if not image_mask_flag_set?
              # Draw left 8 pixels of screen...
              @screen_buffer[true_scanline][scanline_cycle] = @mmc.read_ppu_mem(IMAGE_PALETTE_LO + palette_index)
            end
          else
            @screen_buffer[true_scanline][scanline_cycle] = @mmc.read_ppu_mem(IMAGE_PALETTE_LO + palette_index)
          end
        end

        # Draw sprites
        palette_index = 0
        if sprite_enable_flag_set?
          if not @applicable_sprites.nil?
            # @TODO: Just dealing with 1 sprite for now (need to put in logic for multiple sprites, collisions, etc)
            # @TODO: Deal with 8x16 sprites
            sprite_bytes = @applicable_sprites[0]
            if not sprite_bytes.nil?
              @sprite_y = sprite_bytes[0] + 1
              @sprite_flags = sprite_bytes[2]
              @sprite_pattern_table_index = sprite_bytes[1]
              @sprite_pattern_table_byte1 = @mmc.read_ppu_mem(get_sprite_pattern_table_address + get_pattern_table_byte1_index(@sprite_pattern_table_index, true_scanline - @sprite_y))
              @sprite_pattern_table_byte2 = @mmc.read_ppu_mem(get_sprite_pattern_table_address + get_pattern_table_byte2_index(@sprite_pattern_table_index, true_scanline - @sprite_y))

              @sprite_flags = sprite_bytes[2]
              @sprite_x = sprite_bytes[3]

              palette_index |= ((@sprite_pattern_table_byte1 & PATTERN_TABLE_BIT_MASK[scanline_cycle - @sprite_x]) >> PATTERN_TABLE_BYTE1_BIT_SHIFT[scanline_cycle - @sprite_x])
              palette_index |= ((@sprite_pattern_table_byte2 & PATTERN_TABLE_BIT_MASK[scanline_cycle - @sprite_x]) >> PATTERN_TABLE_BYTE2_BIT_SHIFT[scanline_cycle - @sprite_x])
              palette_index |= ((@sprite_flags & 0x3) << 2)

              if scanline_cycle < 8
                if not sprite_mask_flag_set? and not palette_index == 0
                  # Color #0 is transparent
                  @screen_buffer[true_scanline][scanline_cycle] = @mmc.read_ppu_mem(SPRITE_PALETTE_LO + palette_index)
                end
              elsif not palette_index == 0
                # Color #0 is transparent
                @screen_buffer[true_scanline][scanline_cycle] = @mmc.read_ppu_mem(SPRITE_PALETTE_LO + palette_index)
              end
            end
          end
          
        end
        
      elsif @scanline == 261
        # Again, do nothing
      else 
        # Frame complete
        vblank_hit = true
        @elapsed_cycles = 0
        pre_vblank_cycles = cycle
        
        post_frame
      end 
    }
    
    if (vblank_hit)
      @elapsed_cycles = cycles - pre_vblank_cycles
    else
      @elapsed_cycles += cycles
    end
  end
  
  # PPU Control register 1 Flags
  def get_name_table_address
    result = 0
    
    name_table = @control_reg_1 & PPU_CTRL_1_NAME_TABLE_MASK
    result = 0x2000 + (0x400 * name_table)
    
    return result
  end
  
  def vertical_rw_flag_set?
    # Vertical Read: PPU Address increments by 32 on read or write
    return ((@control_reg_1 & PPU_CTRL_1_VERTICAL_WRITE) != 0) ? true : false
  end
  
  def sprite_pattern_table_address_flag_set?
    result = ((@control_reg_1 & PPU_CTRL_1_SPRITE_PATTERN_TABLE_ADDRESS) != 0) ? true : false
    return result
  end
  
  def get_sprite_pattern_table_address
    result = (sprite_pattern_table_address_flag_set?) ? 0x1000 : 0x0000
    return result
  end
  
  def screen_pattern_table_address_flag_set?
    result = ((@control_reg_1 & PPU_CTRL_1_SCREEN_PATTERN_TABLE_ADDRESS) != 0) ? true : false
    return result
  end
  
  def get_screen_pattern_table_address
    result = (screen_pattern_table_address_flag_set?) ? 0x1000 : 0x0000
    return result
  end
  
  def sprite_size_flag_set?
    return ((@control_reg_1 & PPU_CTRL_1_SPRITE_SIZE) != 0) ? true : false
  end
  
  def vblank_enable_flag_set?
    return ((@control_reg_1 & PPU_CTRL_1_VBLANK_ENABLE) != 0) ? true : false
  end
  
  def set_name_table_address(value)
    @control_reg_1 &= ~PPU_CTRL_1_NAME_TABLE_MASK
    @control_reg_1 |= (value & PPU_CTRL_1_NAME_TABLE_MASK)
  end
  
  def set_vertical_rw_flag(value)
    # Vertical Read: PPU Address increments by 32 on read or write
    if (value)
      @control_reg_1 |= PPU_CTRL_1_VERTICAL_WRITE 
    else 
      @control_reg_1 &= ~PPU_CTRL_1_VERTICAL_WRITE
    end
    
  end
  
  def set_sprite_pattern_table_address_flag(value)
    if (value)
      @control_reg_1 |= PPU_CTRL_1_SPRITE_PATTERN_TABLE_ADDRESS
    else
      @control_reg_1 &= ~PPU_CTRL_1_SPRITE_PATTERN_TABLE_ADDRESS
    end
  end
  
  def set_screen_pattern_table_address_flag(value)
    if (value)
      @control_reg_1 |= PPU_CTRL_1_SCREEN_PATTERN_TABLE_ADDRESS
    else
      @control_reg_1 &= ~PPU_CTRL_1_SCREEN_PATTERN_TABLE_ADDRESS
    end
  end
  
  def set_sprite_size_flag(value)
    if (value)
      @control_reg_1 |= PPU_CTRL_1_SPRITE_SIZE
    else
      @control_reg_1 &= ~PPU_CTRL_1_SPRITE_SIZE
    end
  end
  
 def set_vblank_enable_flag(value)
    if (value)
      @control_reg_1 |= PPU_CTRL_1_VBLANK_ENABLE
    else
      @control_reg_1 &= ~PPU_CTRL_1_VBLANK_ENABLE
    end
  end
  
  # PPU Control register 2 Flags
  def image_mask_flag_set?
    return ((@control_reg_2 & PPU_CTRL_2_IMAGE_MASK) != 0) ? true : false
  end
  
  def sprite_mask_flag_set?
    return ((@control_reg_2 & PPU_CTRL_2_SPRITE_MASK) != 0) ? true : false
  end
  
  def screen_enable_flag_set?
    return ((@control_reg_2 & PPU_CTRL_2_SCREEN_ENABLE) != 0) ? true : false
  end
  
  def sprite_enable_flag_set?
    return ((@control_reg_2 & PPU_CTRL_2_SPRITE_ENABLE) != 0) ? true : false
  end
  
  def get_background_color_bits
    result = @control_reg_2  >> 5
    return result
  end
  
  def set_image_mask_flag(value)
    if (value)
      @control_reg_2 |= PPU_CTRL_2_IMAGE_MASK
    else
      @control_reg_2 &= ~PPU_CTRL_2_IMAGE_MASK
    end
  end
  
  def set_sprite_mask_flag(value)
    if (value)
      @control_reg_2 |= PPU_CTRL_2_SPRITE_MASK
    else
      @control_reg_2 &= ~PPU_CTRL_2_SPRITE_MASK
    end
  end
  
  def set_screen_enable_flag(value)
    if (value)
      @control_reg_2 |= PPU_CTRL_2_SCREEN_ENABLE
    else
      @control_reg_2 &= ~PPU_CTRL_2_SCREEN_ENABLE
    end
  end
  
  def set_sprite_enable_flag(value)
    if (value)
      @control_reg_2 |= PPU_CTRL_2_SPRITE_ENABLE
    else
      @control_reg_2 &= ~PPU_CTRL_2_SPRITE_ENABLE
    end
  end
  
  def set_background_color_bits(value)
    @control_reg_2 &= ~PPU_CTRL_2_BKG_COLOR_MASK
    @control_reg_2 |= (value << 5)
  end
  
  # PPU Status register Flags
  def hit_flag_set?
    return ((@status & PPU_STAT_HIT) != 0) ? true : false
  end
  
  def vblank_flag_set?
    return ((@status & PPU_STAT_VBLANK) != 0) ? true : false
  end
  
  def set_hit_flag(value)
    if (value)
      @status |= PPU_STAT_HIT
    else
      @status &= ~PPU_STAT_HIT
    end
  end
  
  def set_vblank_flag(value)
    if (value)
      @status |= PPU_STAT_VBLANK
    else
      @status &= ~PPU_STAT_VBLANK
    end
  end
  
  def set_background_color
    color = get_background_color_bits
    @background_color = 0x0F  # Default to Black
    case color
      when 0
        @background_color = 0x0F  #Palette Black
      when 1
        @background_color = 0x01  #Palette Blue
      when 2
        @background_color = 0x09  #Palette Green
      when 4
        @background_color = 0x06  #Palette Red
    end
  end
  
  def fill_screen_with_background_color
    @screen_buffer.each { |scanline|
      scanline.fill(@background_color)
    }
  end

  # Sprite stuff
  def get_applicable_sprites(scanline, scanline_cycle, large_size)
    # Note: if 'large_size' = true, sprites are 8x16, otherwise 8x8
    result = []
    height = large_size ? 16 : 8
    width = 8
    y_range = (scanline...(scanline + height))
    x_range = (scanline_cycle...(scanline_cycle + width))
    (0...64).each {|sprite|
      bytes = Array.new(4,0)
      sprite_index = sprite * 4
      bytes[0] = @mmc.sprite_mem[sprite_index]
      bytes[1] = @mmc.sprite_mem[sprite_index + 1]
      bytes[2] = @mmc.sprite_mem[sprite_index + 2]
      bytes[3] = @mmc.sprite_mem[sprite_index + 3]

      if (y_range.include?(bytes[0]+1) and x_range.include?(bytes[3]))
        result << bytes
      end
    }

    return result
  end
  
end